#!/bin/perl -w -T
#
# TheThingsNetwork HTTP letter box sensor notification via E-Mail
#
# (P) & (C) 2021-2021 Dr. Peter Bieringer <pb@bieringer.de>
#
# License: GPLv3
#
# Authors:  Dr. Peter Bieringer (bie)
#
# Supported environment:
#   - TTN_LETTERBOX_DEBUG_NOTIFYEMAIL
#
# Required system features
#   - available Perl module MIME::Lite
#     successfully tested on EL8 using RPM perl-MIME-Lite using
#      smtp via localhost (but this has delays on script response)
#
# Required configuration:
#   - enable sending messages (otherwise dry-run)
#       notifyEmail.enable=1
#
#   - sender E-Mail address (must be permitted to send)
#       EXAMPLE:
#       notifyEmail.sender=postmaster@domain.example
#
# Honors entries starting with "email=" from "@notify_list" provided by main CGI
#
# 20210628/bie: initial version (based on ttn-letterbox-notifyEmail.pm)
#
# TODO: implement faster mail delivery methods like "mailx"

use strict;
use warnings;
use utf8;

require MIME::Lite;

## globals
our %hooks;
our %config;
our %features;
our %translations;
our $language;
our @notify_list;


## prototyping
sub notifyEmail_init();
sub notifyEmail_store_data($$$);


## hooks
$hooks{'notifyEmail'}->{'init'} = \&notifyEmail_init;
$hooks{'notifyEmail'}->{'store_data'} = \&notifyEmail_store_data;

## translations
$translations{'boxstatus'}->{'de'} = "Briefkasten-Status";
$translations{'emptied'}->{'de'} = "AUSGELEERT";
$translations{'filled'}->{'de'} = "GEFÜLLT";
$translations{'at'}->{'de'} = "am";
$translations{'At'}->{'de'} = "Am";

## active status (= passed all validity checks)
my $notifyEmail_active = 0;
my $notifyEmail_enable = 0;


############
## init module
############
sub notifyEmail_init() {
  # set feature
  $features{'notify'} = 1;

  if (defined $ENV{'TTN_LETTERBOX_DEBUG_NOTIFYEMAIL'}) {
    $config{'notifyEmail.debug'} = 1;
  };

  if (defined $config{'notifyEmail.debug'} && $config{'notifyEmail.debug'} eq "0") {
    undef $config{'notifyEmail.debug'};
  };

  logging("notifyEmail/init: called") if defined $config{'notifyEmail.debug'};

  if (! defined $config{'notifyEmail.enable'}) {
    logging("notifyEmail/init/NOTICE: missing entry in config file: notifyEmail.enable -> notifications not enabled") if defined $config{'notifyEmail.debug'};
    $config{'notifyEmail.enable'} = "0";
  };

  if ($config{'notifyEmail.enable'} ne "1") {
    logging("notifyEmail/init/NOTICE: notifyEmail.enable is not '1' -> notifications not enabled") if defined $config{'notifyEmail.debug'};
  } else {
    $notifyEmail_enable = 1;
  };

  if (! defined $config{'notifyEmail.sender'}) {
    logging("notifyEmail/init/ERROR: missing entry in config file: notifyEmail.sender");
    return 0;
  };

  if ($config{'notifyEmail.sender'} !~ /^[0-9a-z\.\-\+]+\@[0-9a-z\.\-]+$/o) {
    logging("notifyEmail/init/ERROR: notifyEmail.sender is not a valid E-Mail address: " . $config{'notifyEmail.sender'});
    return 0;
  };

  $notifyEmail_active = 1;
};


## store data
sub notifyEmail_store_data($$$) {
  my $dev_id = $_[0];
  my $timeReceived = $_[1];
  my $content = $_[2];

  return if ($notifyEmail_active != 1); # nothing to do

  my $sensor = $content->{'dev_id'};
  my $status = $content->{'payload_fields'}->{'box'};

  logging("notifyEmail/store_data: called with sensor=$sensor boxstatus=$status") if defined $config{'notifyEmail.debug'};

  if ($status =~ /^(filled|emptied)$/o) {
    # filter list
    logging("notifyEmail/store_data: notification list: " . join(' ', @notify_list)) if defined $config{'notifyEmail.debug'};
    my @notify_list_filtered = grep /^email=/, @notify_list;

    logging("notifyEmail/store_data: notification list filtered: " . join(' ', @notify_list_filtered)) if defined $config{'notifyEmail.debug'};

    if (scalar(@notify_list_filtered) == 0) {
      logging("notifyEmail/store_data: no related entry found in notification list");
      return 0;
    };

    logging("notifyEmail/store_data: notification list: " . join(' ', @notify_list_filtered)) if defined $config{'notifyEmail.debug'};

    foreach my $receiver (@notify_list_filtered) {
      $receiver =~ s/^email=//o; # remove prefix
      if ($receiver !~ /^([0-9a-z\.\-\+]+\@[0-9a-z\.\-]+)(;[a-z]{2})?$/o) {
        logging("notifyEmail/store_data: notification receiver not a valid E-Mail address + optional language token (SKIP): " . $receiver);
        next;
      };

      my $recipient = $1;

      if (defined $2) {
        $language = $2;
        $language =~ s/^;//o; # remove separator
      };

      my $subject = translate("boxstatus") . ": " . $sensor . " " . translate($status) . " " . translate("at") . " " . strftime("%Y-%m-%d %H:%M:%S %Z", localtime(str2time($timeReceived)));

      logging("notifyEmail/store_data: send notification: $dev_id/$status/$receiver") if defined $config{'notifyEmail.debug'};

      if ($notifyEmail_enable != 1) {
        logging("notifyEmail/store_data/NOTICE: would send E-Mail via MIME::Lite to $recipient (if enabled)");
         # skip
      } else {
        logging("notifyEmail/store_data: call MIME::Lite now with recipient $recipient") if defined $config{'notifyEmail.debug'};
        # action
        my $msg = MIME::Lite->new(
          From     => $config{'notifyEmail.sender'},
          To       => $recipient,
          Subject  => $subject,
          Data     => $subject,
          Encoding => 'base64',
        );

        $msg->send("smtp", "localhost"); # delays end of script
        my $rc = $?;

        logging("notifyEmail/store_data: result of called MIME::Lite: $rc") if defined $config{'notifyEmail.debug'};

        if ($rc == 0) {
          logging("notifyEmail: notification SUCCESS: $dev_id/$status/$receiver");
        } else {
          logging("notifyEmail: notification PROBLEM: $dev_id/$status/$receiver (rc=" . $rc . ")");
        };
      };
    };
  };
};

return 1;

# vim: set noai ts=2 sw=2 et:
