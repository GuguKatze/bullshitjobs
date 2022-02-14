#!/usr/bin/perl -w
#
# A simple Twitter bot that uses the 'search/tweets' Twitter API endpoint
# in order to retweet tweets featuring enough likes or retweets.
#
# TODO: API Error handling.
# 
use strict;
use warnings;
use utf8::all;
use Data::Dumper;
use Twitter::API;
use Term::ANSIColor;
use Date::Parse;
use JSON;
use Getopt::Long;

my $interval = 60 * 20; # interval between runs in seconds

my $profile = undef;
GetOptions( 'profile=s' => \$profile );
if(!defined $profile){
  die dateTime() . ' Please use the --profile=<name of profile> command line option to specify a usage profile. Aborting ...' . "\n";
}

my $twitterUser   = undef;
my $min_retweets  = undef;
my $min_favorites = undef;

###########################################
### configure your search profiles here ###
###########################################

if($profile eq 'pop'){
  $twitterUser   = 'bullshitjobspop';
  $min_retweets  = 10;
  $min_favorites = 10;
}elsif($profile eq 'top'){
  $twitterUser   = 'bullshitjobstop';
  $min_retweets  = 100;
  $min_favorites = 100;
}else{
  die dateTime() . ' Unknown profile "' . $profile . '" specified via the --profile command line option: ' . $profile . '. Aborting ...' . "\n";
}

#########################
### search parameters ###
#########################

my $q = '#bullshitjobs OR bullshitjobs OR bullshit+jobs OR bullshit-jobs OR bullshit_jobs min_retweets:' . $min_retweets . ' OR min_faves:' . $min_favorites;

my $options = {
  q          => $q,
  tweet_mode => 'extended',
  count      => 100,
};

###################################################
### load authentication credentials from config ###
###################################################

my $credentials = do('./credentials.pl');
die color('magenta') . dateTime() . color('reset') . ' No credentials found for user: ' . $twitterUser . '. Aborting ...' . "\n" if !defined $credentials->{$twitterUser};
$credentials = $credentials->{$twitterUser};

my $client = Twitter::API->new_with_traits(
  traits => [ qw/ApiMethods NormalizeBooleans/ ],
  %{$credentials},
);
 
#################
### main loop ###
#################

while(1){

  my $tweetIds = searchForTweets($options);
  print dateTime() . ' Found ' . color('yellow') . scalar(keys(%{$tweetIds})) . color('reset') . ' potential tweets.' . "\n";

  #
  # The results from 'search/tweets' calls do not actually have the .retweeted field set. It's always false/0.
  # This is most likely to prevent search complexity explosions and we need to be doing 'statuses/lookup' calls
  # featuring the ids of our potential tweets. So we know whether we already retweeted them.
  #
  # Another solution would be to try to retweet them anyway and to look for the error.code == 327. Indicating that
  # the tweet got already retweeted by us. But I don't know whether this is considered "good practice" ...
  #
  # See https://twittercommunity.com/t/why-favorited-is-always-false-in-twitter-search-api-1-1/31826
  #

  my $tweetIdsToRetweet = filterRetweeted($tweetIds);
  print dateTime() . ' Retweeting ' . color('yellow') . scalar(keys(%{$tweetIdsToRetweet})) . color('reset') . ' tweets.' . "\n";
  retweetAction($tweetIdsToRetweet);
  
  print dateTime() . ' Sleeping for ' . color('yellow') . $interval . color('reset') . ' seconds. (Next run sheduled for ' . dateTime(time() + $interval) . ')' . "\n";
  sleep($interval);
}

############
### subs ###
############

sub searchForTweets {
  my $options  = shift;
  my $max_id   = undef;
  my $ids      = {};
  do{
    $options->{'max_id'} = $max_id;
    delete $options->{'max_id'} if !defined $options->{'max_id'};   
    print dateTime() . ' max_id: ' . color('yellow') . (defined($max_id) ? $max_id : 'most recent' ) . color('reset') . '.' . "\n";
 
    ################
    ### API call ###
    ################
    my $chunk = $client->get('search/tweets', $options);
    
    foreach my $tweet (@{$chunk->{'statuses'}}){
      $ids->{$tweet->{'id_str'}}++ if isaGoodTweet($tweet);
    }
    $max_id = (defined $chunk->{'search_metadata'}->{'next_results'} && $chunk->{'search_metadata'}->{'next_results'} =~ /max_id=(\d+)/i) ? $1 : undef;
  } while (defined $max_id);
  return $ids;
}

sub isaGoodTweet {
  my $tweet = shift;
  
  return 0 if $tweet->{'retweet_count'} < $min_retweets && $tweet->{'favorite_count'} < $min_favorites;
  return 0 if defined $tweet->{'retweeted_status'};
  return 0 if defined $tweet->{'in_reply_to_status_id_str'};
  return 0 if $tweet->{'lang'} ne 'en';
  
  my $tweetText = defined $tweet->{'retweeted_status'} ? $tweet->{'retweeted_status'}->{'full_text'} : $tweet->{'full_text'};  
  my $matches = 0;
  $matches++ if $tweetText =~ /bullshit[\s\_\-]jobs/i;
  $matches++ if $tweetText =~ /#bullshitjobs/i;
  return 0 if $matches < 1;

  # We found a potential tweet!
  my $unixTime = str2time($tweet->{'created_at'});
  my $tweetUrl      = 'https://twitter.com/' . $tweet->{'user'}->{'screen_name'} . '/status/' . $tweet->{'id_str'};
  my $tweetUrlPrint = 'https://twitter.com/'. color('magenta') . $tweet->{'user'}->{'screen_name'} . color('reset') . '/status/' .  color('yellow') . $tweet->{'id_str'} .  color('reset');
  
  my $retweetCount = $tweet->{'retweet_count'} >= $min_retweets ? color('green') . $tweet->{'retweet_count'} . color('reset') : $tweet->{'retweet_count'};
  my $favoriteCount = $tweet->{'favorite_count'} >= $min_favorites ? color('green') . $tweet->{'favorite_count'} . color('reset') : $tweet->{'favorite_count'};

  my $name = $tweet->{'user'}->{'screen_name'};
  $name = color('yellow') . $name . color('reset') if $tweet->{'user'}->{'verified'};
  
  my $tweetTextShort = substr($tweetText, 0, 128);
  $tweetTextShort =~ s/(^|[^@\w])(@(?:\w{1,15}))\b/$1 . color('magenta') . $2 . color('reset')/ige;
  $tweetTextShort =~ s/(^|[^#\w])(#(?:\w{1,128}))\b/$1 . color('cyan') . $2 . color('reset')/ige;
  my $tweetTextShortPrint = $tweetTextShort;
  $tweetTextShortPrint =~ s/\R//g;
  
  print '[' . color('cyan') . scalar(localtime($unixTime)) . color('reset') . '] ';
  print $tweetUrlPrint . ' 'x(64-length($tweetUrl)) . ' | ';
  print 'R: ' . ' 'x(8 - length($tweet->{'retweet_count'})) . $retweetCount . ' L:' . ' 'x(8 - length($tweet->{'favorite_count'})) . $favoriteCount . ' | ';
  print ' 'x(16 - length($tweet->{'user'}->{'screen_name'})) . $name . ' (' . ' 'x(8 - length($tweet->{'user'}->{'followers_count'})) . $tweet->{'user'}->{'followers_count'} . ') | ';
  print $tweetTextShortPrint;
  print "\n";
  
  return 1;
}

sub filterRetweeted {
  my $ids = shift;
  my $filteredIds = {};

  my @ids = keys %{$ids};
  my $spliceSize = 50;
  do{
    my @tmp = splice(@ids, 0, $spliceSize);
    
    ################
    ### API call ###
    ################
    my $chunk = $client->get('statuses/lookup', { trim_user => 1, id => join(',', @tmp) });
    
    foreach my $tweet (@{$chunk}){
      $filteredIds->{$tweet->{'id_str'}}++ if JSON::is_bool($tweet->{'retweeted'}) && $tweet->{'retweeted'} == JSON::false;
    }
  } while(scalar @ids > 0);
  return $filteredIds;
}

sub retweetAction {
  my $ids = shift;
  foreach my $id (sort {$a <=> $b} keys %{$ids}){
    print dateTime() . ' Retweeting tweet with id: ' . color('yellow') . $id .  color('reset') . '.' . "\n";
    
    ################
    ### API call ###
    ################
    my $chunk = $client->post('statuses/retweet/' . $id);
    
    sleep(5); # Don't hammer the API ...
  }
}

sub dateTime{
  my $unixtime = shift;
  $unixtime = defined $unixtime ? $unixtime : time();
  return '[' . color('magenta') . scalar(localtime($unixtime)) . color('reset') . ']';
}
