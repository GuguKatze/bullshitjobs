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

################
### <config> ###

my $user          = 'bullshitjobstop';
my $min_retweets  = 10;
my $min_favorites = 10;
my $q             = '#bullshitjobs OR bullshitjobs OR bullshit+jobs OR bullshit-jobs OR bullshit_jobs min_retweets:' . $min_retweets . ' OR min_faves:' . $min_favorites;

### </config> ###
#################

my $credentials = do('./credentials.pl');
die color('magenta') . dateTime() . color('reset') . ' No credentials found for user: ' . $user . '. Aborting.' . "\n" if !defined $credentials->{$user};
$credentials = $credentials->{$user};

my $client = Twitter::API->new_with_traits(
  traits => [ qw/ApiMethods NormalizeBooleans/ ],
  %{$credentials},
);
 
my $options = {
  q          => $q,
  tweet_mode => 'extended',
  count      => 100,
};

my $tweetIds = {};
my $max_id   = undef;
do {
  $max_id = getChunk($options, $max_id, $tweetIds);
} while(defined $max_id);
print color('magenta') . dateTime() . color('reset') . ' Found ' . color('yellow') . scalar(keys(%{$tweetIds})) . color('reset') . ' potential tweets.' . "\n";

#
# The results from 'search/tweets' calls do not actually have the .retweeted field set. It's always false/0.
# This is most likely to prevent search complexity explosions and we need to be doing 'statuses/lookup' calls
# featuring the ids of our potential tweets. So we know whether we already retweeted them.
#
# Another solution would be to try to retweet them anyway and to look for the error.code == 327. Indicating that
# the tweet got already retweeted by us. But I don't know whether this is considered "good practise" ...
#
# See https://twittercommunity.com/t/why-favorited-is-always-false-in-twitter-search-api-1-1/31826
#

my $tweetsToRetweet = filterRetweeted($tweetIds);
print color('magenta') . dateTime() . color('reset') . ' Retweeting ' . color('yellow') . scalar(keys(%{$tweetsToRetweet})) . color('reset') . ' tweets.' . "\n";

retweetAction($tweetsToRetweet);


############
### subs ###
############

sub getChunk {
  my $options  = shift;
  my $max_id   = shift;
  $tweetIds    = shift;
  $options->{'max_id'} = $max_id if defined $max_id;
  
  print color('magenta') . dateTime() . color('reset') . ' max_id: ' . color('yellow') . (defined($max_id) ? $max_id : 'most recent' ) . color('reset') . "\n";
  #print Dumper($options) . "\n";
  
  ############
  # API call #
  ############
  my $chunk = $client->get('search/tweets', $options);
  
  foreach my $tweet (@{$chunk->{'statuses'}}){
    $tweetIds->{$tweet->{'id_str'}}++ if isaGoodTweet($tweet);
  }
  $max_id = (defined $chunk->{'search_metadata'}->{'next_results'} && $chunk->{'search_metadata'}->{'next_results'} =~ /max_id=(\d+)/i) ? $1 : undef;
  return $max_id;
}

sub isaGoodTweet {
  my $tweet = shift;
  
  return 0 if $tweet->{'retweet_count'} < $min_retweets && $tweet->{'favorite_count'} < $min_favorites;
  return 0 if defined $tweet->{'retweeted_status'};
  return 0 if defined $tweet->{'in_reply_to_status_id_str'};
  return 0 if $tweet->{'lang'} ne 'en';
  
  my $tweetText = defined $tweet->{'retweeted_status'} ? $tweet->{'retweeted_status'}->{'full_text'} : $tweet->{'full_text'};  
  my $matches = 0;
  $matches ++ if $tweetText =~ /bullshit[\s\_\-]jobs/i;
  $matches ++ if $tweetText =~ /#bullshitjobs/i;
  return 0 if $matches < 1;

  # We found a potential tweet!
  
  my $timestamp =  $tweet->{'created_at'};
  my $unixTime = str2time($timestamp);
  my $tweetUrl      = 'https://twitter.com/' . $tweet->{'user'}->{'screen_name'} . '/status/' . $tweet->{'id_str'};
  my $tweetUrlPrint = 'https://twitter.com/'. color('magenta') . $tweet->{'user'}->{'screen_name'} . color('reset') . '/status/' . $tweet->{'id_str'};
  
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
  my $tweetIds = shift;
  my $filteredTweetIds = {};

  my @ids = keys %{$tweetIds};
  my $spliceSize = 50;
  do{
    my @tmp = splice(@ids, 0, $spliceSize);
    ############
    # API call #
    ############
    my $chunk = $client->get('statuses/lookup', { trim_user => 1, id => join(',', @tmp) });
    foreach my $tweet (@{$chunk}){
    	
    	### 
    	print Dumper($tweet->{'retweeted'}) . "\n"; # <------------ debugging the JSON::PP::Boolean issue ...
    	###
    	
      $filteredTweetIds->{$tweet->{'id_str'}}++ if JSON::is_bool($tweet->{'retweeted'}) && JSON::false($tweet->{'retweeted'});
    }
  } while(scalar @ids > 0);
  return $filteredTweetIds;
}

sub retweetAction {
  my $tweetIds = shift;
  foreach my $id (sort {$a > $b} keys %{$tweetIds}){
    print print color('magenta') . dateTime() . color('reset') . ' Retweeting tweet with id: ' . $id . "\n";
    ################
    ### API call ###
    ################
    my $chunk = $client->post('statuses/retweet/' . $id);
    sleep(5); # Don't hammer the API ...
  }
}

sub dateTime{
  return '[' . scalar(localtime()) . ']';
}
