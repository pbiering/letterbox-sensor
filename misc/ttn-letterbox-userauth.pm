#!/bin/perl -w -T
#
# TheThingsNetwork HTTP letter box user authentication extension
#
# (P) & (C) 2019-2019 Dr. Peter Bieringer <pb@bieringer.de>
#
# License: GPLv3
#
# Authors:  Dr. Peter Bieringer (bie)
#
#
# Supported environment:
#   - TTN_LETTERBOX_DEBUG_USERAUTH
#
# Supported settings in configuration file:
#   - userauth.feature.changepw=1 (currently unfinished)
#
# user file:
#   - name: $datadir . "/ttn.users.list"
#   - format:
#     - htpasswd compatible
#       <username>:<hashed password>:<dev_id_list>|*
#   - new file with new user using bcrypt
#      htpasswd -c -B data/ttn/ttn.users.list <username>
#   - additional user using bcrypt
#       htpasswd -B data/ttn/ttn.users.list <username2>
#   - manually add ACL
#     - either comma separated dev_id_list
#     - or '*' for matching all dev_id
#
#
# generate:
#   - create splitted hash
#
# verify:
#   - verify user/password using htpasswd style file
#   - set cookie wth encrypted TTN-AUTH-TOKEN
#
# verify token
#   - verify contents of encrypted TTN-AUTH-TOKEN
#
# 20191116/bie: initial version
# 20191117/bie: major rework
# 20191118/bie: honor time token from cookie, store expiry in auth cookie
# 20191119/bie: start implementing password change (still unfinished)
# 20191214/bie: add transation "de"

use strict;
use warnings;
use Data::UUID;
use URI::Encode qw(uri_encode uri_decode);
use Digest::SHA qw (sha512_base64 sha512);
use Apache::Htpasswd;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt bcrypt_hash en_base64 de_base64);
use Crypt::CBC;
use utf8;

## globals
our %hooks;
our %config;
our %querystring;
our $conffile;
our $datadir;
our %translations;

# local data
my $session_token_split = 40;
my $session_token_lifetime = 300; # seconds
my $auth_token_lifetime = 86400 * 365; # seconds (1y)
my $auth_token_limit_changepw = 300; # seconds (5 min)
my %cookie_data;
my %post_data;
my %user_data;

# list of configured users
my $userfile;

## prototyping
sub userauth_init();
sub userauth_check();
sub userauth_verify_token();
sub userauth_generate();
sub userauth_verify($);
sub userauth_show();
sub userauth_check_acl($);

## hooks
$hooks{'userauth'}->{'init'} = \&userauth_init;
$hooks{'userauth'}->{'auth_verify_token'} = \&userauth_verify_token;
$hooks{'userauth'}->{'auth_verify'} = \&userauth_verify;
$hooks{'userauth'}->{'auth_check'} = \&userauth_check;
$hooks{'userauth'}->{'auth_generate'} = \&userauth_generate;
$hooks{'userauth'}->{'auth_show'} = \&userauth_show;
$hooks{'userauth'}->{'auth_check_acl'} = \&userauth_check_acl;

## translations
$translations{'authenticated as user'}->{'de'} = "authentifiziert als Benutzer";
$translations{'permitted for devices'}->{'de'} = "erlaubt für Geräte";
$translations{'authentication cookie expires in days'}->{'de'} = "Authentifizierungs-Cookie noch gültig für Tage";
$translations{'Logout'}->{'de'} = "Abmelden";
$translations{'Login'}->{'de'} = "Anmelden";
$translations{'Authentication required'}->{'de'} = "Authentifizierung notwendig";
$translations{'Username'}->{'de'} = "Benutzername";
$translations{'Password'}->{'de'} = "Passwort";
$translations{'Authentication problem'}->{'de'} = "Authentifizierungs-Problem";
$translations{'Login successful'}->{'de'} = "Anmeldung erfolgreich";
$translations{'Logout successful'}->{'de'} = "Abmeldung erfolgreich";
$translations{'Logout already done'}->{'de'} = "Abmeldung bereits erfolgt";
$translations{'username/password not accepted'}->{'de'} = "Benutzername/Passwort nicht akzeptiert";
$translations{'will be redirected back'}->{'de'} = "wird nun zurückgeleitet";


##############
## initialization
##############
sub userauth_init() {
  $userfile = $datadir . "/ttn.users.list";

  if (defined $ENV{'TTN_LETTERBOX_DEBUG_USERAUTH'}) {
    $config{'userauth'}->{'debug'} = 1;
  };

  logging("userauth/init: called") if defined $config{'userauth'}->{'debug'};
};


##############
## check authentication
##############
sub userauth_check() {
  logging("userauth_check") if defined $config{'userauth'}->{'debug'};

  # check cookie
  if (defined $ENV{'HTTP_COOKIE'}) {
    logging("HTTP_COOKIE: " . uri_decode($ENV{'HTTP_COOKIE'})) if defined $config{'userauth'}->{'debug'};
    my $line = $ENV{'HTTP_COOKIE'};
    if ($line =~ /^TTN-AUTH-TOKEN=(.+)/o) {
      parse_querystring(uri_decode($1), \%cookie_data);
      if (defined $cookie_data{'enc'}) {
        # encrypted token
        userauth_verify_token();
      };
    };
  };

  if (! defined $user_data{'username'} && (! defined $post_data{'action'} || $post_data{'action'} ne "login")) {
    userauth_generate();
  };
};


##############
## generate authentication
##############
sub userauth_generate() {
  logging("userauth_generate") if defined $config{'userauth'}->{'debug'};

  my $ug = new Data::UUID;
  my $uuid;
  if (! defined $config{'uuid'}) {
    $uuid = $ug->create();
    logging("config is not containing an uuid, store generated one: " . $ug->to_string($uuid));
    # write uuid to config
    open CONFF, '>>', $conffile or die;
    print CONFF "\n# autogenerated UUID at " . strftime("%Y-%m-%d %H:%M:%S %Z", localtime(time)) . "\n";
    print CONFF "uuid=" . $ug->to_string($uuid) . "\n";
    close CONFF;
  } else {
    $uuid = $ug->from_string($config{'uuid'});
  };

  # generate session token
  my $time = time;
  my $rand = rand();
  my $session_token = sha512_base64("uuid=" . $ug->to_string($uuid) . ":time=" . $time . ":random=" . $rand);
  logging("session generation uuid=" . $ug->to_string($uuid) . " time=" . $time . " rand=" . $rand) if defined $config{'userauth'}->{'debug'};

  # split
  my $session_token_form = substr($session_token, 0, $session_token_split);
  my $session_token_cookie = substr($session_token, $session_token_split);

  if (! defined $ENV{'HTTPS'} || $ENV{'HTTPS'} ne "on") {
    response(401, "<font color=\"red\">Authentication required but not called via HTTPS", "", "HTTPS not enabled");
    exit 0;
  };

  if (! defined $user_data{'username'} || $user_data{'username'} eq "") {
    my $response;
    $response .= "   <b>" . translate("Authentication required") . "</b>\n";
    $response .= "   <form method=\"post\">\n";
    $response .= "    <table border=\"0\" cellspacing=\"0\" cellpadding=\"2\">\n";
    $response .= "     <tr>\n";
    $response .= "      <td>" . translate("Username") . ":</td><td><input id=\"username\" type=\"text\" name=\"username\" style=\"width:200px;height:40px;\"></td>\n";
    $response .= "     </tr>\n";
    $response .= "     <tr>\n";
    $response .= "      <td>" . translate("Password"). ":</td><td><input id=\"password\" type=\"password\" name=\"password\" style=\"width:200px;height:40px;\"></td>\n";
    $response .= "     </tr>\n";
    $response .= "     <tr>\n";
    $response .= "      <td></td><td><input type=\"submit\" value=\"" . translate("Login") . "\" style=\"background-color:#00A000;width:100px;height:50px;\"></td>\n";
    $response .= "     </tr>\n";
    $response .= "    </table>\n";
    $response .= "    <input type=\"text\" name=\"session_token_form\" value=\"" . $session_token_form . "\" hidden>\n";
    $response .= "    <input type=\"text\" name=\"rand\" value=\"" . $rand . "\" hidden>\n";
    $response .= "    <input type=\"text\" name=\"action\" value=\"login\" hidden>\n";
    $response .= "   </form>\n";
    my $cookie = CGI::cookie(-name => 'TTN-AUTH-TOKEN', value => "session_token_cookie=" . $session_token_cookie . "&time=" . $time, -secure => 1, -expires => '+' . $session_token_lifetime . 's', -httponly => 1);
    response(200, $response, "", "", $cookie);
    exit 0;
  };
};


##############
## verify authentication
##############
sub userauth_verify($) {
  logging("userauth_verify") if defined $config{'userauth'}->{'debug'};

  my $cookie = CGI::cookie(-name => 'TTN-AUTH-TOKEN', value => "", -secure => 1, -httponly => 1); # default clear cookie
  my $cookie_found = 0;

  if (! defined $ENV{'CONTENT_TYPE'} || $ENV{'CONTENT_TYPE'} ne "application/x-www-form-urlencoded") {
    # not handling
    return;
  };

  if ($_[0] =~ /^{/o) {
    # looks like start of JSON, not handling
    return;
  };

  # parse form data (if existing)
  parse_querystring($_[0], \%post_data);

  if (! defined $post_data{'action'}) {
    response(500, "unsupported POST data", "", "missing from form: action");
    exit 0;
  };

  if ($post_data{'action'} !~ /^(login|logout|changepw)$/o) {
    response(500, "unsupported POST data", "", "unsupported content from form: action");
    exit 0;
  };

  if (defined $ENV{'HTTP_COOKIE'}) {
    logging("HTTP_COOKIE: " . uri_decode($ENV{'HTTP_COOKIE'})) if defined $config{'userauth'}->{'debug'};
    my $line = $ENV{'HTTP_COOKIE'};
    if ($line =~ /^TTN-AUTH-TOKEN=(.+)/o) {
      $cookie_found = 1;
      parse_querystring(uri_decode($1), \%cookie_data);
    };
  };
 
  if ($post_data{'action'} eq "logout") {
    if (defined $cookie_data{'enc'}) {
      # clear auth token
      response(200, "<font color=\"orange\">" . translate("Logout successful") . " (" . translate("will be redirected back") . ")</font>", "", "", $cookie, 1);
    } else {
      # auth token already cleared
      response(200, "<font color=\"orange\">" . translate("Logout already done") . " (" . translate("will be redirected back") . ")</font>", "", "", $cookie, 1);
    };
    exit 0;
  };

  userauth_check();

  if ($post_data{'action'} eq "changepw") {
    if (defined $cookie_data{'enc'}) {
      response(200, "<font color=\"green\">Authenticated user - change password support will come next</font>", "", "", undef, 1);
    } else {
      # auth token already cleared
      response(401, "<font color=\"orange\">Not authenticated (will be redirected back)</font>", "", "", $cookie, 1);
    };
    exit 0;
  };


  ## Login procedure
  my $ug = new Data::UUID;

  if (! defined $config{'uuid'}) {
    response(500, "<font color=\"red\">Major configuration problem (investigate error log)</font>", "", "no UUID stored in configuration file");
    exit 0;
  };

  my $uuid = $ug->from_string($config{'uuid'});

  if ($cookie_found == 0) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (login session expired or cookies disabled, will be redirected soon)</font>", "", "session expired (no cookie)", $cookie, 10);
    exit 0;
  };

  if (! defined $cookie_data{'session_token_cookie'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie data missing: session_token_cookie", $cookie, 10);
    exit 0;
  };

  if ($cookie_data{'session_token_cookie'} !~ /^[0-9A-Za-z=%\/\+]+$/) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie data length/format mismatch: session_token_cookie", $cookie, 10);
    exit 0;
  };

  if (! defined $cookie_data{'time'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie data missing: time", $cookie, 10);
    exit 0;
  };

  if ($cookie_data{'time'} !~ /^[0-9]{10}$/o) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie data length/format mismatch: time", $cookie, 10);
    exit 0;
  };

  # check post data
  if (! defined $post_data{'session_token_form'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data missing: session_token_form", $cookie, 10);
    exit 0;
  };

  if ($post_data{'session_token_form'} !~ /^[0-9A-Za-z=%\/]+$/o) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data length/format mismatch: session_token_form", $cookie, 10);
    exit 0;
  };

  if (! defined $post_data{'rand'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data missing: rand", $cookie, 10);
    exit 0;
  };

  if ($post_data{'rand'} !~ /^0\.[0-9]+$/o) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data length/format mismatch: rand", $cookie, 10);
    exit 0;
  };

  if (! defined $post_data{'username'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data missing: username");
    exit 0;
  };

  if ($post_data{'username'} !~ /^[0-9A-Za-z]+$/o) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data length/format mismatch: username", $cookie, 10);
    exit 0;
  };

  if (! defined $post_data{'password'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data missing: password", $cookie, 10);
    exit 0;
  };

  if ($post_data{'password'} !~ /^.+$/o) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "form data length/format mismatch: password");
    exit 0;
  };

  # check session token
  my $session_token = uri_decode($post_data{'session_token_form'}) . $cookie_data{'session_token_cookie'};
  my $session_token_reference = sha512_base64("uuid=" . $ug->to_string($uuid) . ":time=" . $cookie_data{'time'} . ":random=" . $post_data{'rand'});
  logging("session verification uuid=" . $ug->to_string($uuid) . " time=" . $cookie_data{'time'} . " rand=" . $post_data{'rand'}) if defined $config{'userauth'}->{'debug'};
  logging("session verification tokenR=" . $session_token_reference) if defined $config{'userauth'}->{'debug'};
  logging("session verification tokenF=" . $session_token) if defined $config{'userauth'}->{'debug'};

  if ($session_token ne $session_token_reference) {
    $cookie = CGI::cookie(-name => 'TTN-AUTH-TOKEN', value => "", -secure => 1, -httponly => 1);
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (login session invalid, will be redirected soon)</font>", "", "session invalid", $cookie, 10);
    exit 0;
  };

  if ($cookie_data{'time'} + $session_token_lifetime < time) {
    $cookie = CGI::cookie(-name => 'TTN-AUTH-TOKEN', value => "", -secure => 1, -httponly => 1);
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (login session expired, will be redirected soon)</font>", "", "session expired", $cookie, 10);
    exit 0;
  };

  if (! -e $userfile) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "no htpasswd user file found: " . $userfile);
    exit 0;
  };

  # look for user in file
  my $htpasswd = new Apache::Htpasswd({passwdFile => $userfile, ReadOnly   => 1});
  if (! defined $htpasswd) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "problem with htpasswd  user file: " . $userfile);
    exit 0;
  };

  my $password_hash = $htpasswd->fetchPass($post_data{'username'});
  if (! defined $password_hash || $password_hash eq "0") {
    response(401, "<font color=\"red\">" . translate("" . translate("Authentication problem") . "") . " (" . translate("username/password not accepted") . ")</font>", "", "user not found in file: " . $userfile . " (" . $post_data{'username'} . ")", $cookie, 10);
    exit 0;
  };

  logging("username=" . $post_data{'username'} . " password=" . $htpasswd->fetchPass($post_data{'username'})) if defined $config{'userauth'}->{'debug'};;

  if ($password_hash =~ /^\$2(.)\$([0-9]+)\$([A-Za-z0-9+\/\.]{22})(.*)$/o) {
    # bcrypt
    my $hash = en_base64(bcrypt_hash({ key_nul => 1, cost => $2, salt => de_base64($3)}, $post_data{'password'}));
    if ($hash ne $4) {
      response(401, "<font color=\"red\">" . translate("Authentication problem") . " (username/password not accepted)</font>", "", "password for user not matching (bcrypt): " . $userfile . " (username=" . $post_data{'username'} . " password_result=" . $hash . ")", $cookie, 10);
      logging("username=" . $post_data{'username'} . " password=" . $htpasswd->fetchPass($post_data{'username'} . " hash=" . $hash)) if defined $config{'userauth'}->{'debug'};;
      exit 0;
    };
  } else {
    # try MD5/SHA1 via module
    my $password_result = $htpasswd->htCheckPassword($post_data{'username'}, $post_data{'password'});
    if (! defined $password_result || $password_result eq "0") {
      response(401, "<font color=\"red\">" . translate("Authentication problem") . " (username/password not accepted)</font>", "", "password for user not matching: " . $userfile . " (username=" . $post_data{'username'} . " password_result=" . $password_result . ")", $cookie, 10);
      exit 0;
    }; 
  };

  # create authentication token
  my $cipher = Crypt::CBC->new(-key => sha512($config{'uuid'}), -cipher => 'Rijndael');
  my $plaintext = "&time=" . time . "&expiry=" . (time + $auth_token_lifetime) . "&username=" . $post_data{'username'} . "&password_hash=" . $password_hash;
  my $ciphertext = $cipher->encrypt($plaintext);
  my $auth_token = encode_base64($ciphertext, "");

  logging("plaintext:" . $plaintext) if defined $config{'userauth'}->{'debug'};
  logging("ciphertext=" . $auth_token) if defined $config{'userauth'}->{'debug'};

  # create cookie
  $cookie = CGI::cookie(-name => 'TTN-AUTH-TOKEN', value => "ver=1&enc=" . $auth_token, -expires => '+' . $auth_token_lifetime . 's', -secure => 1, -httponly => 1);

  $user_data{'userauth'} = $post_data{'username'};
  logging("user successfully authenticated: " . $post_data{'username'});

  response(200, "<font color=\"green\">" . translate("Login successful") . " (" . translate("will be redirected back") . ")</font>", "", "", $cookie, 1);
  exit 0;
};


##############
## verify authentication token
##############
sub userauth_verify_token() {
  logging("userauth_verify_token") if defined $config{'userauth'}->{'debug'};

  my $cookie = CGI::cookie(-name => 'TTN-AUTH-TOKEN', value => "", -secure => 1, -httponly => 1); # default clear cookie

  my $ver = $cookie_data{'ver'};
  if (! defined $cookie_data{'ver'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie is missing: ver", $cookie, 10);
    exit 0;
  };
  if ($cookie_data{'ver'} ne "1") {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie data has unsupported value: ver", $cookie, 10);
    exit 0;
  };

  if (! defined $cookie_data{'enc'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie is missing: enc", $cookie, 10);
    exit 0;
  };
  if ($cookie_data{'enc'} !~ /^[0-9A-Za-z\+\/=]+$/o) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "cookie data has unsupported value: enc", $cookie, 10);
    exit 0;
  };

  # decrypt authentication token
  logging("ciphertext=" . $cookie_data{'enc'}) if defined $config{'userauth'}->{'debug'};
  my $ciphertext = decode_base64(uri_decode($cookie_data{'enc'}));
  my $cipher = Crypt::CBC->new(-key => sha512($config{'uuid'}), -cipher => 'Rijndael');
  my $plaintext = $cipher->decrypt($ciphertext);
  logging("plaintext:" . $plaintext) if defined $config{'userauth'}->{'debug'};

  parse_querystring($plaintext, \%user_data);

  # look for user in file
  my $htpasswd = new Apache::Htpasswd({passwdFile => $userfile, ReadOnly   => 1});
  if (! defined $htpasswd) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "problem with htpasswd  user file: " . $userfile);
    exit 0;
  };

  for my $token ("username", "password_hash", "time", "expiry") {
    if (! defined $user_data{$token}) {
      response(401, "<font color=\"red\">" . translate("Authentication problem") . " (investigate error log)</font>", "", "decrypted cookie is missing: " . $token);
      exit 0;
    };
  };

  my $password_hash = $htpasswd->fetchPass($user_data{'username'});
  if (! defined $password_hash || $password_hash eq "0") {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (username/password not accepted from cookie)</font>", "", "user not found in file: " . $userfile . " (" . $user_data{'username'} . ")", $cookie, 10);
    exit 0;
  };

  logging("from-htpassd-password_hash=" . $password_hash . " from cookie-password_hash=" . $user_data{'password_hash'}) if defined $config{'userauth'}->{'debug'};

  if ($password_hash ne $user_data{'password_hash'}) {
    response(401, "<font color=\"red\">" . translate("Authentication problem") . " (username/password not accepted from cookie)</font>", "", "authentication token invalid", $cookie, 10);
    exit 0;
  };

  # cookie authentication successful fetch optional info
  my $info = $htpasswd->fetchInfo($user_data{'username'});
  if (defined $info && $info ne "") {
    for my $dev_id (split /,/, $info) {
      $user_data{'dev_id_acl'}->{$dev_id} = 1;
    };
  };

  return;
};


##############
## show authentication
##############
sub userauth_show() {
  my $response = "\n";

  return if (!defined $user_data{'username'} || $user_data{'username'} eq ""); # no username -> no info

  $response .= "<table border=\"0\" cellspacing=\"1\" cellpadding=\"1\">\n";
  $response .= " <tr>\n";
  $response .= "  <td>" . translate("authenticated as user") . ": " . $user_data{'username'} . "</td>\n";

  $response .= "  <td rowspan=3>\n";
  $response .= "   <form method=\"post\">\n";
  $response .= "     <input id=\"logout\" type=\"submit\" value=\"" . translate("Logout") . "\" style=\"background-color:#FFA0E0;\">\n";
  $response .= "    <input type=\"text\" name=\"action\" value=\"logout\" hidden>\n";
  $response .= "   </form>\n";
  $response .= "  </td>";

  if (defined $config{"userauth.feature.changepw"} && $config{"userauth.feature.changepw"} eq "1") {
    $response .= "  <td rowspan=3>\n";
    if (time - $user_data{'time'} < $auth_token_limit_changepw) {
      $response .= "   <form method=\"post\">\n";
      $response .= "    <input id=\"changepw\" type=\"submit\" value=\"Change Password\" style=\"background-color:#40A0B0;\">\n";
      $response .= "    <input type=\"text\" name=\"action\" value=\"changepw\" hidden>\n";
      $response .= "   </form>\n";
    } else {
      $response .= "last login longer ago<br />please use logout/login<br />to activate password change option";
    };
    $response .= "  </td>";
  };

  $response .= " </tr>\n";
  $response .= " <tr>\n";
  $response .= "  <td>" . translate("permitted for devices") . ": ";
  if ((defined $user_data{'dev_id_acl'}->{'*'}) && ($user_data{'dev_id_acl'}->{'*'} eq "1")) {
    # wildcard
    $response .= "ALL";
  } elsif (scalar(keys %{$user_data{'dev_id_acl'}}) > 0) {
    $response .= join(",", keys %{$user_data{'dev_id_acl'}});
  } else {
    $response .= "NONE";
  };
  $response .= "</td>\n";
  $response .= " </tr>\n";
  $response .= " <tr>\n";
  $response .= "  <td>";
  if (defined $user_data{'expiry'}) {
    $response .= translate("authentication cookie expires in days") . ": " . int(($user_data{'expiry'} - time) / 86400);
  };
  $response .= "</td>\n";
  $response .= " </tr>\n";
  $response .= "</table>\n";

  return $response;
};


##############
## check acl
## return 1 if permitted, otherwise 0
##############
sub userauth_check_acl($) {
  logging("userauth_check_acl") if defined $config{'userauth'}->{'debug'};

  my $result = 0;

  die if (! defined $_[0]); # input missing
  die if ($_[0] eq ""); # input missing

  $result = 0 if (! defined $user_data{'dev_id_acl'}); # no ACL given
  $result = 0 if (scalar(keys %{$user_data{'dev_id_acl'}}) == 0); # no ACL given

  # Check ACL
  if ((defined $user_data{'dev_id_acl'}->{'*'}) && ($user_data{'dev_id_acl'}->{'*'} eq "1")) {
    # wildcard
    $result = 1;
  } elsif ((defined $user_data{'dev_id_acl'}->{$_[0]}) && ($user_data{'dev_id_acl'}->{$_[0]} eq "1")) {
    $result = 1;
  };

  logging("userauth_check_acl for username=" . $user_data{'username'} . " dev_id=" . $_[0] . " result=" . $result) if defined $config{'userauth'}->{'debug'};

  return($result);
};
