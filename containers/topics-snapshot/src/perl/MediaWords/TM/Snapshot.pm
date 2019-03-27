package MediaWords::TM::Snapshot;

=head1 NAME

MediaWords::TM::Snapshot - Snapshot and analyze topic data

=head1 SYNOPSIS

    # generate a new topic snapshot -- this is run via snapshot_topic.pl once or each snapshot
    snapshot_topic( $db, $topics_id );

    # the rest of these examples are run each time we want to query topic data

    # setup and query snapshot tables
    my $live = 1;
    setup_temporary_snapshot_views( $db, $timespan );

    # query data
    my $story_links = $db->query( "select * from snapshot_story_links" )->hashes;
    my $story_link_counts = $db->query( "select * from story_link_counts" )->hashes;
    my $snapshot_stories = $db->query( "select * from snapshot_stories" )->hashes;

    discard_temp_tables_and_views( $db );

=head1 DESCRIPTION

Analyze a topic and snapshot the topic to snapshot tables and a gexf file.

For detailed explanation of the snapshot process, see doc/snapshots.markdown.

=cut

use strict;
use warnings;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use Date::Format;
use Encode;
use File::Temp;
use FileHandle;
use Getopt::Long;
use List::Util;
use XML::Simple;
use Readonly;

use MediaWords::DBI::Media;
use MediaWords::Solr;
use MediaWords::TM::Alert;
use MediaWords::TM::Model;
use MediaWords::TM::Snapshot::GraphLayout;
use MediaWords::Util::CSV;
use MediaWords::Util::Colors;
use MediaWords::Util::Paths;
use MediaWords::Util::SQL;
use MediaWords::DBI::Activities;

# possible values of snapshots.bot_policy
Readonly our $POLICY_NO_BOTS   => 'no bots';
Readonly our $POLICY_ONLY_BOTS => 'only bots';
Readonly our $POLICY_BOTS_ALL  => 'all';

# max and mind node sizes for gexf snapshot
Readonly my $MAX_NODE_SIZE => 20;
Readonly my $MIN_NODE_SIZE => 2;

# max map width for gexf snapshot
Readonly my $MAX_MAP_WIDTH => 800;

# max number of media to include in gexf map
Readonly my $MAX_GEXF_MEDIA => 500;

# number of tweets per day to use as a threshold for bot filtering
Readonly my $BOT_TWEETS_PER_DAY => 200;

# only layout the gexf export if there are fewer than this number of sources in the graph
Readonly my $MAX_LAYOUT_SOURCES => 2000;

# attributes to include in gexf snapshot
my $_media_static_gexf_attribute_types = {
    url                    => 'string',
    inlink_count           => 'integer',
    story_count            => 'integer',
    view_medium            => 'string',
    media_type             => 'string',
    facebook_share_count   => 'integer',
    simple_tweet_count     => 'integer',
    normalized_tweet_count => 'integer'
};

# all tables that get stored as snapshot_* for each spanshot
my $_snapshot_tables = [
    qw/topic_stories topic_links_cross_media topic_media_codes
      stories media stories_tags_map media_tags_map tags tag_sets tweet_stories/
];

# all tables that get stories as snapshot_* for each timespan
my $_timespan_tables = [ qw/story_link_counts story_links medium_link_counts medium_links timespan_tweets/ ];

# temporary hack to get around snapshot_period_stories lock
my $_drop_snapshot_period_stories = 1;


# update the job state args, catching any error caused by not running within a job
sub _update_job_state_args($$)
{
    my ( $db, $args ) = @_;

    eval { MediaWords::JobManager::Job::update_job_state_args( $db, 'MediaWords::Job::TM::SnapshotTopic', $args ) };
    die( $@ ) if ( $@ && ( $@ !~ /AbstractJob::run_statefully/ ) );
}

# update the job state message, catching any error caused by not running within a job
sub _update_job_state_message($$)
{
    my ( $db, $message ) = @_;

    eval {
        MediaWords::JobManager::Job::update_job_state_message(
            $db,
            'MediaWords::Job::TM::SnapshotTopic',
            $message,
        )
    };
    die( $@ ) if ( $@ && ( $@ !~ /AbstractJob::run_statefully/ ) );
}

# get the list of all snapshot tables
sub _get_snapshot_tables
{
    return [ @{ $_snapshot_tables } ];
}

# get the list of all timespan specific tables
sub _get_timespan_tables
{
    return [ @{ $_timespan_tables } ];
}

# Setup snapshot_* views by creating views for the relevant snap.* tables.
#
# this is useful for writing queries on the snap.* tables without lots of ugly
# joins and clauses to snap and timespan.  It also provides the same set of
# snapshot_* views as provided by write_story_link_counts_snapshot, so that the
# same set of queries can run against either.
#
# The following snapshot_ views are created that contain a copy of all relevant
# rows present in the topic at the time the snapshot was created:
#
# * snapshot_topic_stories
# * snapshot_stories
# * snapshot_media
# * snapshot_topic_links_cross_media
# * snapshot_stories_tags_map
# * snapshot_stories_tags_map
# * snapshot_tag_sets
# * snapshot_media_with_types
#
# The data in each of these views consists of data related to all of the
# stories in the entire topic, not restricted to a specific timespan. So
# snapshot_media includes all media including any story in the topic,
# regardless of date. Each of these views consists of the fields present in the
# snapshot's view.
#
# The following snapshot_ views are created that contain data relevant only to
# the specific timespan and including the following fields:
#
# * snapshot_medium_links:
#     * source_media_id
#     * ref_media_id
#
# * snapshot_story_links:
#     * source_stories_id
#     * ref_stories_id
#
# * snapshot_medium_link_counts:
#     * media_id
#     * inlink_count
#     * outlink_count
#     * story_count
#
# * snapshot_story_link_counts:
#     * stories_id
#     * inlink_count
#     * outlink_count
#     * citly_click_count
#
sub setup_temporary_snapshot_views($$)
{
    my ( $db, $timespan ) = @_;

    # postgres prints lots of 'NOTICE's when deleting temp tables
    $db->set_print_warn( 0 );

    for my $t ( @{ _get_snapshot_tables() } )
    {
        $db->query( <<"SQL" );
            CREATE TEMPORARY VIEW snapshot_$t AS
                SELECT *
                FROM snap.$t
                WHERE snapshots_id = $timespan->{ snapshots_id }
SQL
    }

    for my $t ( @{ _get_timespan_tables() } )
    {
        $db->query( <<"SQL" )
            CREATE TEMPORARY VIEW snapshot_$t AS
                SELECT *
                FROM snap.$t
                WHERE timespans_id = $timespan->{ timespans_id }
SQL
    }

    $db->query( <<SQL
        CREATE TEMPORARY VIEW snapshot_period_stories AS
            SELECT stories_id
            FROM snapshot_story_link_counts
SQL
    );

    _add_media_type_views( $db );
}

# Runs $db->query( "discard temp" ) to clean up temporary tables and views.
# This should be run after calling setup_temporary_snapshot_views(). Calling
# setup_temporary_snapshot_views() within a transaction and committing the
# transaction will have the same effect.
sub discard_temp_tables_and_views
{
    my ( $db ) = @_;

    $db->query( "discard temp" );
}

# remove stories from snapshot_period_stories that don't math solr query in the
# associated focus, if any
sub _restrict_period_stories_to_focus
{
    my ( $db, $timespan ) = @_;

    return unless ( $timespan->{ foci_id } );

    my $qs = $db->query( "select *, arguments->>'query' query from foci where foci_id = ?", $timespan->{ foci_id } )->hash;

    my $snapshot_period_stories_ids = $db->query( "select stories_id from snapshot_period_stories" )->flat;

    if ( !@{ $snapshot_period_stories_ids } )
    {
        $db->query( "truncate table snapshot_period_stories" );
        return;

    }
    my $all_stories_ids      = [ @{ $snapshot_period_stories_ids } ];
    my $matching_stories_ids = [];
    my $chunk_size           = 1000;
    my $min_chunk_size       = 10;
    my $max_solr_errors      = 25;
    my $solr_error_count     = 0;

    while ( @{ $all_stories_ids } )
    {
        my $chunk_stories_ids = [];
        my $chunk_size = List::Util::min( $chunk_size, scalar( @{ $all_stories_ids } ) );
        map { push( @{ $chunk_stories_ids }, shift( @{ $all_stories_ids } ) ) } ( 1 .. $chunk_size );

        my $solr_q = $qs->{ query };

        die( "focus boolean query '$solr_q' must include non-space character" ) unless ( $solr_q =~ /[^[:space:]]/ );

        my $stories_ids_list = join( ' ', @{ $chunk_stories_ids } );
        $solr_q = "( $solr_q ) and stories_id:( $stories_ids_list )";

        my $solr_stories_ids =
          eval { MediaWords::Solr::search_for_stories_ids( $db, { rows => 1000000, q => $solr_q } ) };
        if ( $@ )
        {
            # sometimes solr throws a NullException error on one of these queries; retrying with smaller
            # chunks seems to make it happy; if the error keeps happening, just drop those stories_ids
            if ( ++$solr_error_count > $max_solr_errors )
            {
                die( "too many solr errors: $@" );
            }

            $chunk_size = List::Util::max( $chunk_size / 2, $min_chunk_size );
            unshift( @{ $all_stories_ids }, @{ $chunk_stories_ids } );
            sleep( int( 2**( 1 * ( $solr_error_count / 5 ) ) ) );
        }
        else
        {
            push( @{ $matching_stories_ids }, @{ $solr_stories_ids } );
        }
    }

    $matching_stories_ids = [ map { int( $_ ) } @{ $matching_stories_ids } ];

    DEBUG( "restricting timespan to focus query: " . scalar( @{ $matching_stories_ids } ) . " stories" );

    my $ids_table = $db->get_temporary_ids_table( $matching_stories_ids );

    $db->query( "delete from snapshot_period_stories where stories_id not in ( select id from $ids_table )" );
}

# get the where clause that will restrict the snapshot_period_stories creation
# to only stories within the timespan time frame
sub _get_period_stories_date_where_clause
{
    my ( $timespan ) = @_;

    my $date_clause = <<END;
( ( s.publish_date between \$1::timestamp and \$2::timestamp - interval '1 second'
      and s.stories_id not in ( select stories_id from snapshot_undateable_stories ) ) or
  ( ss.publish_date between \$1::timestamp and \$2::timestamp - interval '1 second'
      and ss.stories_id not in ( select stories_id from snapshot_undateable_stories ) )
)
END

    return $date_clause;
}

# for a twitter topic, the only stories that should appear in the timespan are stories associated
# with a tweet published during the timespan
sub _create_twitter_snapshot_period_stories($$)
{
    my ( $db, $timespan ) = @_;

    $db->query( <<SQL, $timespan->{ timespans_id } );
create temporary table snapshot_period_stories as
    select distinct stories_id
        from snapshot_tweet_stories ts
            join timespans t on ( timespans_id = \$1 )
        where
            ts.publish_date between t.start_date and t.end_date
SQL
}

# restrict the set of stories to the current timespan based on publish date or referencing story
# publish date.  a story should be in the current snapshot if either its date is within
# the period dates or if a story that links to it has a date within the period dates.
# For this purpose, stories tagged with the 'date_invalid:undateable' tag
# are considered to have an invalid tag, so their dates cannot be used to pass
# either of the above tests.
sub _create_link_snapshot_period_stories($$)
{
    my ( $db, $timespan ) = @_;

    $db->query( <<END );
create or replace temporary view snapshot_undateable_stories as
select distinct s.stories_id
    from snapshot_stories s, snapshot_stories_tags_map stm, snapshot_tags t, snapshot_tag_sets ts
    where s.stories_id = stm.stories_id and
        stm.tags_id = t.tags_id and
        t.tag_sets_id = ts.tag_sets_id and
        ts.name = 'date_invalid' and
        t.tag = 'undateable'
END

    my $date_where_clause = _get_period_stories_date_where_clause( $timespan );

    $db->query( <<"END", $timespan->{ start_date }, $timespan->{ end_date } );
create temporary table snapshot_period_stories as
select distinct s.stories_id
    from snapshot_stories s
        left join snapshot_topic_links_cross_media cl on ( cl.ref_stories_id = s.stories_id )
        left join snapshot_stories ss on ( cl.stories_id = ss.stories_id )
    where
        $date_where_clause
END

    $db->query( "drop view snapshot_undateable_stories" );
}

# return true if the topic of the timespan is a twitter_topic
sub _topic_is_twitter_topic
{
    my ( $db, $timespan ) = @_;

    my ( $is_twitter_topic ) = $db->query( <<SQL, $timespan->{ snapshots_id } )->flat;
select 1
    from topics t
        join snapshots s using ( topics_id )
    where
        t.ch_monitor_id is not null and
        s.snapshots_id = \$1
SQL

    $is_twitter_topic ||= 0;

    return $is_twitter_topic;
}

# write snapshot_period_stories table that holds list of all stories that should be included in the
# current period.  For an overall snapshot, every story should be in the current period.
# the definition of period stories depends on whether the topic is a twitter topic or not.
#
# The resulting snapshot_period_stories should be used by all other snapshot queries to determine
# story membership within a give period.
sub _write_period_stories
{
    my ( $db, $timespan ) = @_;

    $db->query( "drop table if exists snapshot_period_stories" );

    if ( !$timespan || ( $timespan->{ period } eq 'overall' ) )
    {
        $db->query( <<END );
create temporary table snapshot_period_stories as select stories_id from snapshot_stories
END
    }
    elsif ( _topic_is_twitter_topic( $db, $timespan ) )
    {
        _create_twitter_snapshot_period_stories( $db, $timespan );
    }
    else
    {
        _create_link_snapshot_period_stories( $db, $timespan );
    }

    my ( $num_period_stories ) = $db->query( "select count(*) from snapshot_period_stories" )->flat;
    DEBUG( "num_period_stories: $num_period_stories" );

    if ( $timespan->{ foci_id } )
    {
        _restrict_period_stories_to_focus( $db, $timespan );
    }
}

# convenience function to update a field in the timespan table
sub update_timespan
{
    my ( $db, $timespan, $field, $val ) = @_;

    $db->update_by_id( 'timespans', $timespan->{ timespans_id }, { $field => $val } );
}

sub _write_story_links_snapshot
{
    my ( $db, $timespan, $is_model ) = @_;

    $db->query( "drop table if exists snapshot_story_links" );

    if ( _topic_is_twitter_topic( $db, $timespan ) )
    {
        $db->query(
            <<SQL
create temporary table snapshot_story_links as

    with tweet_stories as (
        select s.media_id, s.stories_id, s.twitter_user, s.publish_date
            from snapshot_tweet_stories s
                join snapshot_timespan_tweets t using ( topic_tweets_id )
    ),

    coshared_links as (
        select
                a.stories_id stories_id_a, a.twitter_user, b.stories_id stories_id_b
            from
                tweet_stories a
                join tweet_stories b using ( twitter_user )
            where
                a.media_id <> b.media_id and
                date_trunc( 'day', a.publish_date ) = date_trunc( 'day', b.publish_date )
            group by a.stories_id, b.stories_id, a.twitter_user
    )

    select cs.stories_id_a source_stories_id, cs.stories_id_b ref_stories_id
        from coshared_links cs
        group by cs.stories_id_a, cs.stories_id_b
SQL
        );
    }
    else
    {
        $db->query( <<END );
create temporary table snapshot_story_links as
    select distinct cl.stories_id source_stories_id, cl.ref_stories_id
	    from snapshot_topic_links_cross_media cl
            join snapshot_period_stories sps on ( cl.stories_id = sps.stories_id )
            join snapshot_period_stories rps on ( cl.ref_stories_id = rps.stories_id )
            left join stories_ap_syndicated sap on ( sps.stories_id = sap.stories_id )
    	where
            ( ( sap.ap_syndicated is null ) or ( sap.ap_syndicated = false ) )
END
    }

    # re-enable above to prevent post-dated links
    #          ss.publish_date > rs.publish_date - interval '1 day' and

    if ( !$is_model )
    {
        _create_timespan_snapshot( $db, $timespan, 'story_links' );
    }
}

sub _write_timespan_tweets_snapshot
{
    my ( $db, $timespan, $is_model ) = @_;

    $db->query( "drop table if exists snapshot_timespan_tweets" );

    my $start_date_q = $db->quote( $timespan->{ start_date } );
    my $end_date_q   = $db->quote( $timespan->{ end_date } );

    my $date_clause =
      $timespan->{ period } eq 'overall'
      ? '1=1'
      : "publish_date between $start_date_q and $end_date_q";

    my $snapshot = $db->require_by_id( 'snapshots', $timespan->{ snapshots_id } );
    my $topic    = $db->require_by_id( 'topics',    $snapshot->{ topics_id } );

    $db->query( <<SQL );
create temporary table snapshot_timespan_tweets as
    select distinct ts.topic_tweets_id
        from snapshot_tweet_stories ts
            join snapshot_period_stories s using ( stories_id )
            join snapshot_media m using ( media_id )
        where
            m.url not like '%twitter.com%' and
            $date_clause
SQL

    if ( !$is_model )
    {
        _create_timespan_snapshot( $db, $timespan, 'timespan_tweets' );
    }
}

sub _write_story_link_counts_snapshot
{
    my ( $db, $timespan, $is_model ) = @_;

    $db->query( "drop table if exists snapshot_story_link_counts" );

    $db->query( <<END );
create temporary table snapshot_story_link_counts as
    with  snapshot_story_media_links as (
       select
            s.media_id source_media_id,
            sl.ref_stories_id ref_stories_id
        from
            snapshot_story_links sl
            join snapshot_stories s on ( s.stories_id = sl.source_stories_id )
        group by s.media_id, sl.ref_stories_id
    ),

    snapshot_story_media_link_counts as (
        select
                count(*) media_inlink_count,
                sml.ref_stories_id stories_id
            from
                snapshot_story_media_links sml
            group by sml.ref_stories_id
    ),

    snapshot_twitter_counts as (
        select
                s.stories_id,
                count( distinct ts.twitter_user ) as simple_tweet_count,
                sum( ( num_ch_tweets::float + 1 ) / ( tweet_count + 1 ) ) as normalized_tweet_count
            from snapshot_tweet_stories ts
                join snapshot_period_stories s using ( stories_id )
                join snapshot_timespan_tweets tt using ( topic_tweets_id )
            group by s.stories_id
    )

    select distinct ps.stories_id,
            coalesce( smlc.media_inlink_count, 0 ) media_inlink_count,
            coalesce( ilc.inlink_count, 0 ) inlink_count,
            coalesce( olc.outlink_count, 0 ) outlink_count,
            stc.simple_tweet_count,
            stc.normalized_tweet_count,
            ss.facebook_share_count facebook_share_count
        from snapshot_period_stories ps
            left join snapshot_story_media_link_counts smlc using ( stories_id )
            left join
                ( select sl.ref_stories_id,
                         count( distinct sl.source_stories_id ) inlink_count
                  from snapshot_story_links sl,
                       snapshot_period_stories ps
                  where sl.source_stories_id = ps.stories_id
                  group by sl.ref_stories_id
                ) ilc on ( ps.stories_id = ilc.ref_stories_id )
            left join
                ( select sl.source_stories_id stories_id,
                         count( distinct sl.ref_stories_id ) outlink_count
                  from snapshot_story_links sl,
                       snapshot_period_stories ps
                  where sl.ref_stories_id = ps.stories_id
                  group by sl.source_stories_id
                ) olc on ( ps.stories_id = olc.stories_id )
            left join story_statistics ss
                on ss.stories_id = ps.stories_id
            left join snapshot_twitter_counts stc
                on stc.stories_id = ps.stories_id
END

    if ( !$is_model )
    {
        _create_timespan_snapshot( $db, $timespan, 'story_link_counts' );
    }
}

sub _add_partisan_code_to_snapshot_media
{
    my ( $db, $timespan, $media ) = @_;

    my $label = 'partisan_code';

    my $partisan_tags = $db->query( <<END )->hashes;
select dmtm.*, dt.tag
    from snapshot_media_tags_map dmtm
        join snapshot_tags dt on ( dmtm.tags_id = dt.tags_id )
        join snapshot_tag_sets dts on ( dts.tag_sets_id = dt.tag_sets_id )
    where
        dts.name = 'collection' and
        dt.tag like 'partisan_2012_%'
END

    my $map = {};
    map { $map->{ $_->{ media_id } } = $_->{ tag } } @{ $partisan_tags };

    map { $_->{ $label } = $map->{ $_->{ media_id } } || 'null' } @{ $media };

    return $label;
}

sub _add_partisan_retweet_to_snapshot_media
{
    my ( $db, $timespan, $media ) = @_;

    my $label = 'partisan_retweet';

    my $partisan_tags = $db->query( <<END )->hashes;
select dmtm.*, dt.tag
    from snapshot_media_tags_map dmtm
        join snapshot_tags dt on ( dmtm.tags_id = dt.tags_id )
        join snapshot_tag_sets dts on ( dts.tag_sets_id = dt.tag_sets_id )
    where
        dts.name = 'retweet_partisanship_2016_count_10'
END

    my $map = {};
    map { $map->{ $_->{ media_id } } = $_->{ tag } } @{ $partisan_tags };

    map { $_->{ $label } = $map->{ $_->{ media_id } } || 'null' } @{ $media };

    return $label;
}

sub _add_fake_news_to_snapshot_media
{
    my ( $db, $timespan, $media ) = @_;

    my $label = 'fake_news';

    my $tags = $db->query( <<END )->hashes;
select dmtm.*, dt.tag
    from snapshot_media_tags_map dmtm
        join snapshot_tags dt on ( dmtm.tags_id = dt.tags_id )
        join snapshot_tag_sets dts on ( dts.tag_sets_id = dt.tag_sets_id )
    where
        dts.name = 'collection' and
        dt.tag = 'fake_news_20170112'
END

    my $map = {};
    map { $map->{ $_->{ media_id } } = $_->{ tag } ? 1 : 0 } @{ $tags };

    map { $_->{ $label } = $map->{ $_->{ media_id } } || 0 } @{ $media };

    return $label;
}

# add tags, codes, partisanship and other extra data to all snapshot media for the purpose
# of making a gexf or csv snapshot.  return the list of extra fields added.
sub _add_extra_fields_to_snapshot_media
{
    my ( $db, $timespan, $media ) = @_;

    my $partisan_field = _add_partisan_code_to_snapshot_media( $db, $timespan, $media );
    my $partisan_retweet_field = _add_partisan_retweet_to_snapshot_media( $db, $timespan, $media );
    my $fake_news_field = _add_fake_news_to_snapshot_media( $db, $timespan, $media );

    my $all_fields = [ $partisan_field, $partisan_retweet_field, $fake_news_field ];

    map { $_media_static_gexf_attribute_types->{ $_ } = 'string'; } @{ $all_fields };

    return $all_fields;
}

# Get an encoded csv snapshot of the media in the given timespan.
sub get_media_csv
{
    my ( $db, $timespan ) = @_;

    my $res = $db->query( <<END );
select m.name, m.url, mlc.*
    from snapshot_media m, snapshot_medium_link_counts mlc
    where m.media_id = mlc.media_id
    order by mlc.media_inlink_count desc;
END

    my $fields = $res->columns;
    my $media  = $res->hashes;

    my $extra_fields = _add_extra_fields_to_snapshot_media( $db, $timespan, $media );

    push( @{ $fields }, @{ $extra_fields } );

    my $csv = MediaWords::Util::CSV::get_hashes_as_encoded_csv( $media, $fields );

    return $csv;
}

sub _write_medium_link_counts_snapshot
{
    my ( $db, $timespan, $is_model ) = @_;

    $db->query( "drop table if exists snapshot_medium_link_counts" );

    $db->query( <<END );
create temporary table snapshot_medium_link_counts as

    with medium_media_link_counts as (
       select
            count(*) media_inlink_count,
            dml.ref_media_id media_id
        from
            snapshot_medium_links dml
        group by dml.ref_media_id
    ),

    medium_link_counts as (
        select m.media_id,
               sum( slc.media_inlink_count ) sum_media_inlink_count,
               sum( slc.inlink_count) inlink_count,
               sum( slc.outlink_count) outlink_count,
               count(*) story_count,
               sum( slc.facebook_share_count ) facebook_share_count,
               sum( slc.simple_tweet_count ) simple_tweet_count,
               sum( slc.normalized_tweet_count ) normalized_tweet_count
            from
                snapshot_media m
                join snapshot_stories s using ( media_id )
                join snapshot_story_link_counts slc using ( stories_id )
            where m.media_id = s.media_id and s.stories_id = slc.stories_id
            group by m.media_id
    )

    select
            mlc.*,
            coalesce( mmlc.media_inlink_count, 0 ) media_inlink_count
        from medium_link_counts mlc
            left join medium_media_link_counts mmlc using ( media_id )
END

    if ( !$is_model )
    {
        _create_timespan_snapshot( $db, $timespan, 'medium_link_counts' );
    }
}

sub _write_medium_links_snapshot
{
    my ( $db, $timespan, $is_model ) = @_;

    $db->query( "drop table if exists snapshot_medium_links" );

    $db->query( <<END );
create temporary table snapshot_medium_links as
    select s.media_id source_media_id, r.media_id ref_media_id, count(*) link_count
        from snapshot_story_links sl, snapshot_stories s, snapshot_stories r
        where sl.source_stories_id = s.stories_id and sl.ref_stories_id = r.stories_id
        group by s.media_id, r.media_id
END

    if ( !$is_model )
    {
        _create_timespan_snapshot( $db, $timespan, 'medium_links' );
    }
}

# return only the $edges that are within the giant component of the network
sub _trim_to_giant_component($)
{
    my ( $edges ) = @_;

    my $edge_pairs = [ map { [ $_->{ source }, $_->{ target } ] } @{ $edges } ];

    my $trimmed_edges = MediaWords::TM::Snapshot::GraphLayout::giant_component( $edge_pairs );

    my $edge_lookup = {};
    map { $edge_lookup->{ $_->[ 0 ] }->{ $_->[ 1 ] } = 1 } @{ $trimmed_edges };

    my $links = [ grep { $edge_lookup->{ $_->{ source } }->{ $_->{ target } } } @{ $edges } ];

    DEBUG( "_trim_to_giant_component: " . scalar( @{ $edges } ) . " -> " . scalar( @{ $links } ) );

    return $links;
}

sub _get_weighted_edges
{
    my ( $db, $media, $options ) = @_;

    my $max_media            = $options->{ max_media };
    my $include_weights      = $options->{ include_weights } || 0;
    my $max_links_per_medium = $options->{ max_links_per_medium } || 1_000_000;

    DEBUG(<<"EOF"
_get_weighted_edges:
    * $max_media max media;
    * $include_weights include_weights;
    * $max_links_per_medium max_links_per_medium
EOF
    );

    my $media_links = $db->query( <<SQL,

        WITH top_media AS (
            SELECT *
            FROM snapshot_medium_link_counts
            ORDER BY media_inlink_count DESC
            LIMIT \$1
        ),

        ranked_media AS (
            SELECT
                *,
                ROW_NUMBER() OVER (
                    PARTITION BY source_media_id
                    ORDER BY
                        l.link_count DESC,
                        rlc.inlink_count DESC
                ) AS source_rank
            FROM snapshot_medium_links AS l
                JOIN top_media AS slc
                    ON l.source_media_id = slc.media_id
                JOIN top_media AS rlc
                    ON l.ref_media_id = rlc.media_id
        )

        SELECT *
        FROM ranked_media
        WHERE source_rank <= \$2

SQL
        $max_media, $max_links_per_medium
    )->hashes;

    my $media_map = {};
    map { $media_map->{ $_->{ media_id } } = 1 } @{ $media };

    my $edges = [];
    my $k     = 0;
    for my $media_link ( @{ $media_links } )
    {
        next unless ( $media_map->{ $media_link->{ source_media_id } } && $media_map->{ $media_link->{ ref_media_id } } );
        my $edge = {
            id     => $k++,
            source => $media_link->{ source_media_id },
            target => $media_link->{ ref_media_id },
            weight => ( $include_weights ? $media_link->{ link_count } : 1 )
        };

        push( @{ $edges }, $edge );
    }

    $edges = _trim_to_giant_component( $edges );

    return $edges;
}

# given an rgb hex string, return a hash in the form { r => 12, g => 0, b => 255 }, which is
# what we need for the viz:color element of the gexf snapshot
sub _get_color_hash_from_hex
{
    my ( $rgb_hex ) = @_;

    return {
        r => hex( substr( $rgb_hex, 0, 2 ) ),
        g => hex( substr( $rgb_hex, 2, 2 ) ),
        b => hex( substr( $rgb_hex, 4, 2 ) )
    };
}

# get a consistent color from MediaWords::Util::Colors.  convert to a color hash as needed by gexf.  translate
# the set to a topic specific color set value for get_consistent_color.
sub _get_color
{
    my ( $db, $timespan, $set, $id ) = @_;

    my $color_set;
    if ( grep { $_ eq $set } qw(partisan_code media_type partisan_retweet) )
    {
        $color_set = $set;
    }
    else
    {
        $color_set = "topic_${set}_$timespan->{ snapshot }->{ topics_id }";
    }

    $id ||= 'none';

    my $color = MediaWords::Util::Colors::get_consistent_color( $db, $color_set, $id );

    return _get_color_hash_from_hex( $color );
}

# scale the nodes such that the biggest node size is $MAX_NODE_SIZE and the smallest is $MIN_NODE_SIZE
sub _scale_node_sizes
{
    my ( $nodes ) = @_;

    map { $_->{ 'viz:size' }->{ value } += 1 } @{ $nodes };

    my $max_size = 1;
    for my $node ( @{ $nodes } )
    {
        my $s = $node->{ 'viz:size' }->{ value };
        $max_size = $s if ( $max_size < $s );
    }

    my $scale = $MAX_NODE_SIZE / $max_size;

    for my $node ( @{ $nodes } )
    {
        my $s = $node->{ 'viz:size' }->{ value };

        $s = int( $scale * $s );

        $s = $MIN_NODE_SIZE if ( $s < $MIN_NODE_SIZE );

        $node->{ 'viz:size' }->{ value } = $s;
    }
}

# call mediawords.tm.snapshot.graph_layout.layout_gexf
sub _layout_gexf($)
{
    my ( $gexf ) = @_;

    my $nodes = $gexf->{ graph }->[ 0 ]->{ nodes }->{ node };

    my $layout;

    if ( scalar( @{ $nodes } ) < $MAX_LAYOUT_SOURCES )
    {
        DEBUG( "laying out grap with " . scalar( @{ $nodes } ) . " sources ..." );
        my $xml = XML::Simple::XMLout( $gexf, XMLDecl => 1, RootName => 'gexf' );

        $layout = MediaWords::TM::Snapshot::GraphLayout::layout_gexf( $xml );
    }
    else
    {
        WARN( "refusing to layout graph with more than $MAX_LAYOUT_SOURCES sources" );
        $layout = {};
    }

    for my $node ( @{ $nodes } )
    {
        my $pos = $layout->{ $node->{ id } };
        my ( $x, $y ) = $pos ? @{ $pos } : ( 0, 0 );
        $node->{ 'viz:position' }->{ x } = $x;
        $node->{ 'viz:position' }->{ y } = $y;
    }
}

# get a descirption for the gexf file export
sub _get_gexf_description($$)
{
    my ( $db, $timespan ) = @_;

    my $topic = $db->query( <<SQL, $timespan->{ snapshots_id } )->hash;
select * from topics t join snapshots s using ( topics_id ) where snapshots_id = ?
SQL

    my $description = <<END;
Media Cloud topic map of $topic->{ name } for $timespan->{ period } timespan
from $timespan->{ start_date } to $timespan->{ end_date }
END

    if ( $timespan->{ foci_id } )
    {
        my $focus = $db->require_by_id( 'foci', $timespan->{ foci_id } );
        $description .= "for $focus->{ name } focus";
    }

    return $description;
}

# Get a gexf snapshot of the graph described by the linked media sources within
# the given topic timespan.
#
# Layout the graph using the gaphviz neato algorithm.
#
# Accepts these $options:
#
# * color_field - color the nodes by the given field: $medium->{ $color_field }
#   (default 'media_type').
# * max_media -  include only the $max_media media sources with the most
#   inlinks in the timespan (default 500).
# * include_weights - if true, use weighted edges
# * max_links_per_medium - if set, only include the top $max_links_per_media
#   out links from each medium, sorted by medium_link_counts.link_count and
#   then inlink_count of the target medium
# * exclude_media_ids - list of media_ids to exclude
sub get_gexf_snapshot
{
    my ( $db, $timespan, $options ) = @_;

    $options->{ max_media }   ||= $MAX_GEXF_MEDIA;
    $options->{ color_field } ||= 'media_type';

    my $exclude_media_ids_list = join( ',', map { int( $_ ) } ( @{ $options->{ exclude_media_ids } }, 0 ) );

    my $media = $db->query( <<END, $options->{ max_media } )->hashes;
select distinct
        m.*,
        mlc.media_inlink_count inlink_count,
        mlc.story_count,
        mlc.facebook_share_count,
        mlc.simple_tweet_count,
        mlc.normalized_tweet_count
    from snapshot_media_with_types m
        join snapshot_medium_link_counts mlc using ( media_id )
    where
        m.media_id not in ( $exclude_media_ids_list )
    order
        by mlc.media_inlink_count desc
    limit ?
END

    _add_extra_fields_to_snapshot_media( $db, $timespan, $media );

    my $gexf = {
        'xmlns'              => "http://www.gexf.net/1.2draft",
        'xmlns:xsi'          => "http://www.w3.org/2001/XMLSchema-instance",
        'xmlns:viz'          => "http://www.gexf.net/1.1draft/viz",
        'xsi:schemaLocation' => "http://www.gexf.net/1.2draft http://www.gexf.net/1.2draft/gexf.xsd",
        'version'            => "1.2",
    };

    my $meta = { 'lastmodifieddate' => Date::Format::time2str( '%Y-%m-%d', time ) };
    push( @{ $gexf->{ meta } }, $meta );

    push( @{ $meta->{ creator } }, 'Berkman Center' );

    my $description = _get_gexf_description( $db, $timespan );
    push( @{ $meta->{ description } }, $description );

    my $graph = {
        'mode'            => "static",
        'defaultedgetype' => "directed",
    };
    push( @{ $gexf->{ graph } }, $graph );

    my $attributes = { class => 'node', mode => 'static' };
    push( @{ $graph->{ attributes } }, $attributes );

    my $i = 0;
    while ( my ( $name, $type ) = each( %{ $_media_static_gexf_attribute_types } ) )
    {
        push( @{ $attributes->{ attribute } }, { id => $i++, title => $name, type => $type } );
    }

    my $edges = _get_weighted_edges( $db, $media, $options );
    $graph->{ edges }->{ edge } = $edges;

    my $edge_lookup;
    map { $edge_lookup->{ $_->{ source } } = 1; $edge_lookup->{ $_->{ target } } = 1; } @{ $edges };

    my $total_link_count = 1;
    map { $total_link_count += $_->{ inlink_count } } @{ $media };

    for my $medium ( @{ $media } )
    {
        next unless ( $edge_lookup->{ $medium->{ media_id } } );

        my $node = {
            id    => $medium->{ media_id },
            label => $medium->{ name },
        };

        # FIXME should this be configurable?
        $medium->{ view_medium } = 'https://sources.mediacloud.org/#/sources/' . $medium->{ media_id };

        my $j = 0;
        while ( my ( $name, $type ) = each( %{ $_media_static_gexf_attribute_types } ) )
        {
            my $value = $medium->{ $name };
            if ( !defined( $value ) )
            {
                $value = ( $type eq 'integer' ) ? 0 : '';
            }

            push( @{ $node->{ attvalues }->{ attvalue } }, { for => $j++, value => $value } );
        }

        my $color_field = $options->{ color_field };
        $node->{ 'viz:color' } = [ _get_color( $db, $timespan, $color_field, $medium->{ $color_field } ) ];
        $node->{ 'viz:size' } = { value => $medium->{ inlink_count } + 1 };

        push( @{ $graph->{ nodes }->{ node } }, $node );
    }

    _scale_node_sizes( $graph->{ nodes }->{ node } );

    _layout_gexf( $gexf );

    my $xml = XML::Simple::XMLout( $gexf, XMLDecl => 1, RootName => 'gexf' );

    return $xml;
}

sub _create_timespan($$$$$$)
{
    my ( $db, $cd, $start_date, $end_date, $period, $focus ) = @_;

    my $snapshots_id = $cd->{ snapshots_id };
    my $foci_id = $focus ? $focus->{ foci_id } : undef;

    my $focus_clause = $foci_id ? "foci_id = $foci_id" : "foci_id is null";

    my $timespan = $db->query( <<SQL, $snapshots_id, $start_date, $end_date, $period, $foci_id )->hash();
select *
    from timespans
    where
        snapshots_id = \$1 and
        start_date = \$2 and
        end_date = \$3 and
        period = \$4 and
        $focus_clause
SQL

    $timespan ||= $db->query( <<SQL, $snapshots_id, $start_date, $end_date, $period, $foci_id )->hash();
insert into timespans
    ( snapshots_id, start_date, end_date, period, foci_id, 
      story_count, story_link_count, medium_count, medium_link_count, tweet_count )
    values ( \$1, \$2, \$3, \$4, \$5, 0, 0, 0, 0, 0 )
    returning *
SQL

    $timespan->{ snapshot } = $cd;

    return $timespan;
}

# return true if there exists at least one row in the relevant table for which timespans_id = $timespans_id
sub _timespan_snapshot_exists($$$)
{
    my ( $db, $table, $timespan ) = @_;

    die( "Table name can only have letters and underscores" ) if ( $table =~ /[^a-z_]/i );

    my $exists = $db->query( "select 1 from snap.$table where timespans_id = ?", $timespan->{ timespans_id } )->hash();

    return $exists;
}

# generate data for the story_links, story_link_counts, media_links, media_link_counts tables
# based on the data in the temporary snapshot_* tables
sub generate_timespan_data($$;$)
{
    my ( $db, $timespan, $is_model ) = @_;

    if ( _timespan_snapshot_exists( $db, 'medium_link_counts', $timespan ) )
    {
        DEBUG( "timespan already exists.  skipping ..." );
        return;
    }

    my $all_models_top_media = MediaWords::TM::Model::get_all_models_top_media( $db, $timespan );

    _write_period_stories( $db, $timespan );

    _write_timespan_tweets_snapshot( $db, $timespan );

    _write_story_links_snapshot( $db, $timespan, $is_model );
    _write_story_link_counts_snapshot( $db, $timespan, $is_model );
    _write_medium_links_snapshot( $db, $timespan, $is_model );
    _write_medium_link_counts_snapshot( $db, $timespan, $is_model );

    _update_timespan_counts( $db, $timespan );

    $all_models_top_media ||= [ MediaWords::TM::Model::get_top_media_link_counts( $db, $timespan ) ];

    MediaWords::TM::Model::print_model_matches( $db, $timespan, $all_models_top_media );
    MediaWords::TM::Model::update_model_correlation( $db, $timespan, $all_models_top_media );
}

# Update story_count, story_link_count, medium_count, and medium_link_count
# fields in the timespan hash. This must be called after
# setup_temporary_snapshot_views() to get access to these fields in the
# timespan hash.
#
# Save to db unless $live is specified.
sub _update_timespan_counts($$;$)
{
    my ( $db, $timespan, $live ) = @_;

    ( $timespan->{ story_count } ) = $db->query( "select count(*) from snapshot_story_link_counts" )->flat;

    ( $timespan->{ story_link_count } ) = $db->query( "select count(*) from snapshot_story_links" )->flat;

    ( $timespan->{ medium_count } ) = $db->query( "select count(*) from snapshot_medium_link_counts" )->flat;

    ( $timespan->{ medium_link_count } ) = $db->query( "select count(*) from snapshot_medium_links" )->flat;

    ( $timespan->{ tweet_count } ) = $db->query( "select count(*) from snapshot_timespan_tweets" )->flat;

    return if ( $live );

    for my $field ( qw(story_count story_link_count medium_count medium_link_count) )
    {
        update_timespan( $db, $timespan, $field, $timespan->{ $field } );
    }
}

# generate the snapshot timespans for the given period, dates, and tag
sub _generate_timespan($$$$$$)
{
    my ( $db, $cd, $start_date, $end_date, $period, $focus ) = @_;

    my $timespan = _create_timespan( $db, $cd, $start_date, $end_date, $period, $focus );

    my $snapshot_label = "${ period }: ${ start_date } - ${ end_date } ";
    $snapshot_label .= "[ $focus->{ name } ]" if ( $focus );

    DEBUG( "generating $snapshot_label ..." );

    update_job_state_message( $db, "snapshotting $snapshot_label" );

    DEBUG( "generating snapshot data ..." );
    generate_timespan_data( $db, $timespan );
}

# decrease the given date to the latest monday equal to or before the date
sub _truncate_to_monday($)
{
    my ( $date ) = @_;

    my $epoch_date = MediaWords::Util::SQL::get_epoch_from_sql_date( $date );
    my $week_day   = ( localtime( $epoch_date ) )[ 6 ];

    # mod this to account for sunday, for which $week_day - 1 == -1
    my $days_offset = ( $week_day - 1 ) % 7;

    return MediaWords::Util::SQL::increment_day( $date, -1 * $days_offset );
}

# decrease the given date to the first day of the current month
sub _truncate_to_start_of_month ($)
{
    my ( $date ) = @_;

    my $epoch_date = MediaWords::Util::SQL::get_epoch_from_sql_date( $date );
    my $month_day  = ( localtime( $epoch_date ) )[ 3 ];

    my $days_offset = $month_day - 1;

    return MediaWords::Util::SQL::increment_day( $date, -1 * $days_offset );
}

# generate snapshots for the periods in topic_dates
sub _generate_custom_period_snapshot ($$$ )
{
    my ( $db, $cd, $focus ) = @_;

    my $topic_dates = $db->query( <<END, $cd->{ topics_id } )->hashes;
select * from topic_dates where topics_id = ? order by start_date, end_date
END

    for my $topic_date ( @{ $topic_dates } )
    {
        my $start_date = $topic_date->{ start_date };
        my $end_date   = $topic_date->{ end_date };
        _generate_timespan( $db, $cd, $start_date, $end_date, 'custom', $focus );
    }
}

# generate snapshot for the given period (overall, monthly, weekly, or custom) and the given tag
sub _generate_period_snapshot($$$$)
{
    my ( $db, $cd, $period, $focus ) = @_;

    my $start_date = $cd->{ start_date };
    my $end_date   = $cd->{ end_date };

    if ( $period eq 'overall' )
    {
        # this will generate an 'overall' timespan with all stories
        _generate_timespan( $db, $cd, $start_date, $end_date, $period, $focus );
    }
    elsif ( $period eq 'weekly' )
    {
        my $w_start_date = _truncate_to_monday( $start_date );
        while ( $w_start_date lt $end_date )
        {
            my $w_end_date = MediaWords::Util::SQL::increment_day( $w_start_date, 7 );

            _generate_timespan( $db, $cd, $w_start_date, $w_end_date, $period, $focus );

            $w_start_date = $w_end_date;
        }
    }
    elsif ( $period eq 'monthly' )
    {
        my $m_start_date = _truncate_to_start_of_month( $start_date );
        while ( $m_start_date lt $end_date )
        {
            my $m_end_date = MediaWords::Util::SQL::increment_day( $m_start_date, 32 );
            $m_end_date = _truncate_to_start_of_month( $m_end_date );

            _generate_timespan( $db, $cd, $m_start_date, $m_end_date, $period, $focus );

            $m_start_date = $m_end_date;
        }
    }
    elsif ( $period eq 'custom' )
    {
        _generate_custom_period_snapshot( $db, $cd, $focus );
    }
    else
    {
        die( "Unknown period '$period'" );
    }
}

# create a snapshot for the given table from the temporary snapshot_* table,
# making sure to specify all the fields in the copy so that we don't have to
# assume column position is the same in the original and snapshot tables.
# use the $key from $obj as an additional field in the snapshot table.
sub _create_snapshot
{
    my ( $db, $obj, $key, $table ) = @_;

    DEBUG( "snapshot $table..." );

    die( "Table name can only have letters and underscores" ) if ( $table =~ /[^a-z_]/i );
    die( "Key can only have letters and underscores" )        if ( $key =~ /[^a-z_]/i );

    my $snapshot_exists = $db->query( "select 1 from snap.$table where $key = $obj->{ $key }" )->hash();
    if ( $snapshot_exists )
    {
        DEBUG( "snapshot $table already exists.  skipping ..." );
        return;
    }

    my $column_names = [ $db->query( <<END, $table, $key )->flat ];
select column_name from information_schema.columns
    where table_name = ? and table_schema = 'snap' and
        column_name not in ( ? )
    order by ordinal_position asc
END

    die( "Field names can only have letters and underscores" ) if ( grep { /[^a-z_]/i } @{ $column_names } );

    my $column_list = join( ",", @{ $column_names } );

    $db->query( <<END, $obj->{ $key } );
insert into snap.${ table } ( $column_list, $key ) select $column_list, ? from snapshot_${ table }
END

}

# create a snapshot of a table for a timespan
sub _create_timespan_snapshot
{
    my ( $db, $timespan, $table ) = @_;

    _create_snapshot( $db, $timespan, 'timespans_id', $table );
}

# create a snapshot of a table for a snapshot
sub create_snap_snapshot
{
    my ( $db, $cd, $table ) = @_;

    _create_snapshot( $db, $cd, 'snapshots_id', $table );
}

# generate temporary snapshot_* tables for the specified snapshot for each of the snapshot_tables.
# these are the tables that apply to the whole snapshot.
sub _write_temporary_snapshot_tables($$$)
{
    my ( $db, $topic, $snapshot ) = @_;

    my $topics_id = $topic->{ topics_id };

    $db->query( <<END, $topics_id );
create temporary table snapshot_topic_stories as
    select cs.*
        from topic_stories cs
        where cs.topics_id = ?
END

    $db->query( <<END, $topics_id );
create temporary table snapshot_topic_media_codes as
    select cmc.*
        from topic_media_codes cmc
        where cmc.topics_id = ?
END

    $db->query( <<SQL,
        CREATE TEMPORARY TABLE snapshot_stories AS
            SELECT
                s.stories_id,
                s.media_id,
                s.url,
                s.guid,
                s.title,
                s.publish_date,
                s.collect_date,
                s.full_text_rss,
                s.language
            FROM snap.live_stories AS s
                JOIN snapshot_topic_stories AS dcs
                    ON s.stories_id = dcs.stories_id
                   AND s.topics_id = ?
SQL
        $topics_id
    );

    $db->query( <<END );
create temporary table snapshot_media as
    select m.* from media m
        where m.media_id in ( select media_id from snapshot_stories )
END

    $db->query( <<END, $topics_id );
create temporary table snapshot_topic_links_cross_media as
    select s.stories_id, r.stories_id ref_stories_id, cl.url, cs.topics_id, cl.topic_links_id
        from topic_links cl
            join snapshot_topic_stories cs on ( cs.stories_id = cl.ref_stories_id )
            join snapshot_stories s on ( cl.stories_id = s.stories_id )
            join snapshot_media sm on ( s.media_id = sm.media_id )
            join snapshot_stories r on ( cl.ref_stories_id = r.stories_id )
            join snapshot_media rm on ( r.media_id= rm.media_id )
        where cl.topics_id = ? and r.media_id <> s.media_id
END

    $db->query( <<END );
create temporary table snapshot_stories_tags_map as
    select stm.*
    from stories_tags_map stm, snapshot_stories ds
    where stm.stories_id = ds.stories_id
END

    $db->query( <<END );
create temporary table snapshot_media_tags_map as
    select mtm.*
    from media_tags_map mtm, snapshot_media dm
    where mtm.media_id = dm.media_id
END

    $db->query( <<END );
create temporary table snapshot_tags as
    select distinct t.* from tags t where t.tags_id in
        ( select a.tags_id
            from tags a
                join snapshot_media_tags_map amtm on ( a.tags_id = amtm.tags_id )

          union

          select b.tags_id
            from tags b
                join snapshot_stories_tags_map bstm on ( b.tags_id = bstm.tags_id )
        )

END

    $db->query( <<END );
create temporary table snapshot_tag_sets as
    select ts.*
        from tag_sets ts
        where ts.tag_sets_id in ( select tag_sets_id from snapshot_tags )
END

    my $tweet_topics_id = $topic->{ topics_id };

    my $bot_clause = '';
    my $bot_policy = $snapshot->{ bot_policy } || $POLICY_NO_BOTS;
    if ( $bot_policy eq $POLICY_NO_BOTS )
    {
        $bot_clause = "and ( ( coalesce( tweets, 0 ) / coalesce( days, 1 ) ) < $BOT_TWEETS_PER_DAY )";
    }
    elsif ( $bot_policy eq $POLICY_ONLY_BOTS )
    {
        $bot_clause = "and ( ( coalesce( tweets, 0 ) / coalesce( days, 1 ) ) >= $BOT_TWEETS_PER_DAY )";
    }

    $db->query( <<SQL, $tweet_topics_id );
create temporary table snapshot_tweet_stories as
    with tweets_per_day as (
        select topic_tweets_id,
                ( tt.data->'tweet'->'user'->>'statuses_count' ) ::int tweets,
                extract( day from now() - ( tt.data->'tweet'->'user'->>'created_at' )::date ) days
            from topic_tweets tt
                join topic_tweet_days ttd using ( topic_tweet_days_id )
            where ttd.topics_id = \$1
    )

    select topic_tweets_id, u.publish_date, twitter_user, stories_id, media_id, num_ch_tweets, tweet_count
        from topic_tweet_full_urls u
            join tweets_per_day tpd using ( topic_tweets_id )
            join snapshot_stories using ( stories_id )
        where
            topics_id = \$1 $bot_clause
SQL

    _add_media_type_views( $db );

    for my $table ( @{ _get_snapshot_tables() } )
    {
        my $table_exists = $db->query( "select * from pg_class where relname = ?", $table )->hash;
        die( "snapshot not created for snapshot table: $table" ) unless ( $table_exists );
    }

}

sub _add_media_type_views
{
    my ( $db ) = @_;

    $db->query( <<SQL

        CREATE OR REPLACE VIEW snapshot_media_with_types AS
            WITH topics_id AS (
                SELECT topics_id
                FROM snapshot_topic_stories
                LIMIT 1
            )

            SELECT
                m.*,
                CASE
                    WHEN (ct.label != 'Not Typed') THEN ct.label
                    WHEN (ut.label IS NOT NULL) THEN ut.label
                    ELSE 'Not Typed'
                END AS media_type

            FROM snapshot_media AS m

                LEFT JOIN (
                    snapshot_tags AS ut

                        JOIN snapshot_tag_sets AS uts
                            ON ut.tag_sets_id = uts.tag_sets_id
                           AND uts.name = 'media_type'

                        JOIN snapshot_media_tags_map AS umtm
                            on umtm.tags_id = ut.tags_id

                ) ON m.media_id = umtm.media_id

                LEFT JOIN (
                    snapshot_tags AS ct

                        JOIN snapshot_media_tags_map AS cmtm
                            ON cmtm.tags_id = ct.tags_id
                        JOIN topics AS c
                            ON c.media_type_tag_sets_id = ct.tag_sets_id
                        JOIN topics_id AS cid
                            ON c.topics_id = cid.topics_id
                ) ON m.media_id = cmtm.media_id

SQL
    );

    $db->query( <<SQL );
        CREATE OR REPLACE VIEW snapshot_stories_with_types AS
            SELECT
                s.*,
                m.media_type
            FROM snapshot_stories AS s
                JOIN snapshot_media_with_types AS m
                    ON s.media_id = m.media_id
SQL

}

# generate snapshots for all of the _get_snapshot_tables() from the temporary snapshot tables
sub _generate_snapshots_from_temporary_snapshot_tables
{
    my ( $db, $cd ) = @_;

    my $snapshot_tables = _get_snapshot_tables();

    map { create_snap_snapshot( $db, $cd, $_ ) } @{ $_snapshot_tables };
}

# create the snapshot row for the current snapshot
sub _create_snapshot_row ($$$$;$$)
{
    my ( $db, $topic, $start_date, $end_date, $note, $bot_policy ) = @_;

    $note //= '';

    my $cd = $db->query( <<END, $topic->{ topics_id }, $start_date, $end_date, $note, $bot_policy )->hash;
insert into snapshots
    ( topics_id, start_date, end_date, snapshot_date, note, bot_policy )
    values ( ?, ?, ?, now(), ?, ?)
    returning *
END

    $cd->{ topic } = $topic;

    return $cd;
}

# generate period spanshots for each period / focus / timespan combination
sub _generate_period_focus_snapshots ( $$$ )
{
    my ( $db, $snapshot, $periods ) = @_;

    my $fsds = $db->query( <<SQL, $snapshot->{ topics_id } )->hashes;
select * from focal_set_definitions where topics_id = ? and focal_technique = 'Boolean Query'
SQL

    for my $fsd ( @{ $fsds } )
    {
        my $focal_set = $db->query( <<SQL, $fsd->{ focal_set_definitions_id }, $snapshot->{ snapshots_id } )->hash;
insert into focal_sets ( name, description, focal_technique, snapshots_id )
    select name, description, focal_technique, \$2 from focal_set_definitions where focal_set_definitions_id = \$1
    on conflict (snapshots_id, name) do update set snapshots_id = \$2
    returning *
SQL

        my $fds = $db->query( <<SQL, $fsd->{ focal_set_definitions_id } )->hashes;
select * from focus_definitions where focal_set_definitions_id = \$1
SQL

        for my $fd ( @{ $fds } )
        {
            my $focus = $db->query( <<SQL, $fd->{ focus_definitions_id }, $focal_set->{ focal_sets_id } )->hash;
insert into foci ( name, description, arguments, focal_sets_id )
    select name, description, arguments, \$2 from focus_definitions where focus_definitions_id = \$1
    on conflict ( focal_sets_id, name ) do update set focal_sets_id = \$2
    returning *
SQL
            map { _generate_period_snapshot( $db, $snapshot, $_, $focus ) } @{ $periods };
        }
    }
}

# put all stories in this dump in solr_extra_import_stories for export to solr
sub _export_stories_to_solr($$)
{
    my ( $db, $cd ) = @_;

    DEBUG( "queueing stories for solr import ..." );
    $db->query( <<SQL, $cd->{ snapshots_id } );
insert into solr_import_stories ( stories_id )
    select distinct stories_id from snap.stories where snapshots_id = ?
SQL

    $db->update_by_id( 'snapshots', $cd->{ snapshots_id }, { searchable => 'f' } );
}

# die if each of the $periods is not among the $allowed_periods
sub _validate_periods($$)
{
    my ( $periods, $allowed_periods ) = @_;

    for my $period ( @{ $allowed_periods } )
    {
        die( "uknown period: '$period'" ) unless ( grep { $period eq $_ } @{ $allowed_periods } );
    }
}

# Create a snapshot for the given topic.  Optionally pass a note and/or a bot_policy field to the created snapshot.
#
# The bot_policy should be one of 'all', 'no bots', or 'only bots' indicating for twitter topics whether and how to
# filter for bots (a bot is defined as any user tweeting more than 200 post per day).
#
# The periods should be a list of periods to include in the snapshot, where the allowed periods are custom,
# overall, weekly, and monthly.  If periods is not specificied or is empty, all periods will be generated.
#
# If a snapshots_id is provided, use the existing snapshot.  Otherwise, create a new one.
#
# Returns snapshots_id of the provided or newly created snapshot.
sub snapshot_topic ($$;$$$$)
{
    my ( $db, $topics_id, $snapshots_id, $note, $bot_policy, $periods ) = @_;

    my $allowed_periods = [ qw(custom overall weekly monthly) ];

    $periods = $allowed_periods if ( !$periods || !@{ $periods } );

    _validate_periods( $periods, $allowed_periods );

    my $topic = $db->find_by_id( 'topics', $topics_id )
      || die( "Unable to find topic '$topics_id'" );

    $db->set_print_warn( 0 );    # avoid noisy, extraneous postgres notices from drops

    # Log activity that's about to start
    my $changes = {};
    unless ( MediaWords::DBI::Activities::log_system_activity( $db, 'tm_snapshot_topic', $topics_id + 0, $changes ) )
    {
        die "Unable to log the 'tm_snapshot_topic' activity.";
    }

    my ( $start_date, $end_date ) = ( $topic->{ start_date }, $topic->{ end_date } );

    my $snap =
        $snapshots_id
      ? $db->require_by_id( 'snapshots', $snapshots_id )
      : _create_snapshot_row( $db, $topic, $start_date, $end_date, $note, $bot_policy );

    _update_job_state_args( $db, { snapshots_id => $snap->{ snapshots_id } } );
    _update_job_state_message( $db, "snapshotting data" );

    _write_temporary_snapshot_tables( $db, $topic, $snap );

    _generate_snapshots_from_temporary_snapshot_tables( $db, $snap );

    # generate null focus timespan snapshots
    map { _generate_period_snapshot( $db, $snap, $_, undef ) } ( @{ $periods } );

    _generate_period_focus_snapshots( $db, $snap, $periods );

    _update_job_state_message( $db, "finalizing snapshot" );

    _export_stories_to_solr( $db, $snap );

    discard_temp_tables_and_views( $db );

    # update this manually because snapshot_topic might be called directly from mine_topic()
    $db->update_by_id( 'snapshots', $snap->{ snapshots_id }, { state => $MediaWords::AbstractJob::STATE_COMPLETED } );
    MediaWords::TM::Alert::send_topic_alert( $db, $topic, "new topic snapshot is ready" );

    return $snap->{ snapshots_id };
}

1;
