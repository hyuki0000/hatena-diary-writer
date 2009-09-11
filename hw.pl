#!/usr/bin/perl
#
# hw.pl - Hatena Diary Writer.
#
# Copyright (C) 2004,2005,2007 by Hiroshi Yuki.
# http://www.hyuki.com/techinfo/hatena_diary_writer.html
#
# Special thanks to:
# - Ryosuke Nanba http://d.hatena.ne.jp/rna/
# - Hahahaha http://www20.big.or.jp/~rin_ne/
# - Ishinao http://ishinao.net/
#
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#
use strict;
my $VERSION = "1.4.1";

use LWP::UserAgent;
use HTTP::Request::Common;
use HTTP::Cookies;
use File::Basename;
use Getopt::Std;
use Digest::MD5 qw(md5_base64);

my $enable_encode = eval('use Encode; 1');

# Prototypes.
sub login();
sub get_rkm($$$$$$$$$$$);
sub logout();
sub update_diary_entry($$$$$$);
sub delete_diary_entry($);
sub doit_and_retry($$);
sub create_it($$$);
sub delete_it($);
sub post_it($$$$$$);
sub get_timestamp();
sub print_debug(@);
sub print_message(@);
sub read_title_body($);
sub find_image_file($);
sub replace_timestamp($);
sub error_exit(@);
sub load_config();

# Hatena user id (if empty, I will ask you later).
my $username = '';
# Hatena password (if empty, I will ask you later).
my $password = '';
# Hatena group name (for hatena group user only).
my $groupname = '';

# Default file names.
my $touch_file = 'touch.txt';
my $cookie_file = 'cookie.txt';
my $config_file = 'config.txt';
my $target_file = '';

# Filter command.
# e.g. 'iconv -f euc-jp -t utf-8 %s'
# where %s is filename, output is stdout.
my $filter_command = '';

# Proxy setting.
my $http_proxy = '';

# Directory for "YYYY-MM-DD.txt".
my $txt_dir = ".";

# Client and server encodings.
my $client_encoding = '';
my $server_encoding = '';

# Hatena URL.
my $hatena_url = 'http://d.hatena.ne.jp';
my $hatena_sslregister_url = 'https://www.hatena.ne.jp/login';

# Crypt::SSLeay check.
eval {
    require Crypt::SSLeay;
};
if ($@) {
    print_message("WARNING: Crypt::SSLeay is not found, use non-encrypted HTTP mode.");
    $hatena_sslregister_url = 'http://www.hatena.ne.jp/login';
}

# Option for LWP::UserAgent.
my %ua_option = (
    agent => "HatenaDiaryWriter/$VERSION", # "Mozilla/5.0",
    timeout => 180,
);

# Other variables.
my $delete_title = 'delete';
my $cookie_jar;
my $user_agent;
my $rkm; # session id for posting.

# Handle command-line option.
my %cmd_opt = (
    'd' => 0,   # "debug" flag.
    't' => 0,   # "trivial" flag.
    'u' => "",  # "username" option.
    'p' => "",  # "password" option.
    'a' => "",  # "agent" option.
    'T' => "",  # "timeout" option.
    'c' => 0,   # "cookie" flag.
    'g' => "",  # "groupname" option.
    'f' => "",  # "file" option.
    'M' => 0,   # "no timestamp" flag.
    'n' => "",  # "config file" option.
    'S' => 1,   # "SSL" option. This is always 1. Set 0 to login older hatena server.
);

$Getopt::Std::STANDARD_HELP_VERSION = 1;
getopts("tdu:p:a:T:cg:f:Mn:", \%cmd_opt) or error_exit("Unknown option.");

if ($cmd_opt{d}) {
    print_debug("Debug flag on.");
    print_debug("Cookie flag on.") if $cmd_opt{c};
    print_debug("Trivial flag on.") if $cmd_opt{t};
    &VERSION_MESSAGE();
}

# Override config file name (before load_config).
$config_file = $cmd_opt{n} if $cmd_opt{n};

# Override global vars with config file.
load_config() if -e($config_file);

# Override global vars with command-line options.
$username = $cmd_opt{u} if $cmd_opt{u};
$password = $cmd_opt{p} if $cmd_opt{p};
$groupname = $cmd_opt{g} if $cmd_opt{g};
$ua_option{agent} = $cmd_opt{a} if $cmd_opt{a};
$ua_option{timeout} = $cmd_opt{T} if $cmd_opt{T};
$target_file = $cmd_opt{f} if $cmd_opt{f};

# Change $hatena_url to Hatena group URL if ($groupname is defined).
if ($groupname) {
    $hatena_url = "http://$groupname.g.hatena.ne.jp";
}

# Start.
&main;

# no-error exit.
exit(0);

# Main sequence.
sub main {
    my $count = 0;
    my @files;

    # Setup file list.
    if ($cmd_opt{f}) {
        # Do not check timestamp.
        push(@files, $cmd_opt{f});
        print_debug("main: files: option -f: @files");
    } else {
        while (glob("$txt_dir/*.txt")) {
            # Check timestamp.
            next if (-e($touch_file) and (-M($_) > -M($touch_file)));
            push(@files, $_);
        }
        print_debug("main: files: current dir ($txt_dir): @files");
    }

    # Process it.
    for (@files) {
        # Check file name.
        next unless (/\b(\d\d\d\d)-(\d\d)-(\d\d)\.txt$/);

        my ($year, $month, $day) = ($1, $2, $3);
        my $date = $year . $month . $day;

        # Check if it is a file.
        next unless (-f $_);

        # Login if necessary.
        login() unless ($user_agent);

        # Replace "*t*" unless suppressed.
        replace_timestamp($_) unless ($cmd_opt{M});

        # Read title and body.
        my ($title, $body) = read_title_body($_);

        # Find image files.
        my $imgfile = find_image_file($_);

        if ($title eq $delete_title) {
            # Delete entry.
            print_message("Delete $year-$month-$day.");
            delete_diary_entry($date);
            print_message("Delete OK.");
        } else {
            # Update entry.
            print_message("Post $year-$month-$day.  " . ($imgfile ? " (image: $imgfile)" : ""));
            update_diary_entry($year, $month, $day, $title, $body, $imgfile);
            print_message("Post OK.");
        }

        sleep(1);

        $count++;
    }

    # Logout if necessary.
    logout if ($user_agent);

    if ($count == 0) {
        print_message("No files are posted.");
    } else {
        unless ($cmd_opt{f}) {
            # Touch file.
            open(FILE, "> $touch_file") or die "$!:$touch_file\n";
            print FILE get_timestamp;
            close(FILE);
        }
    }
}

# Login.
sub login() {
    $user_agent = LWP::UserAgent->new(%ua_option);
    $user_agent->env_proxy;
    if ($http_proxy) {
        $user_agent->proxy('http', $http_proxy);
        print_debug("login: proxy for http: $http_proxy");
        $user_agent->proxy('https', $http_proxy);
        print_debug("login: proxy for https: $http_proxy");
    }

    # Ask username if not set.
    unless ($username) {
        print "Username: ";
        chomp($username = <STDIN>);
    }

    # If "cookie" flag is on, and cookie file exists, do not login.
    if ($cmd_opt{c} and -e($cookie_file)) {
        print_debug("login: Loading cookie jar.");

        $cookie_jar = HTTP::Cookies->new;
        $cookie_jar->load($cookie_file);
        $cookie_jar->scan(\&get_rkm);

        print_debug("login: \$cookie_jar = " . $cookie_jar->as_string);

        print_message("Skip login.");

        return;
    }

    # Ask password if not set.
    unless ($password) {
        print "Password: ";
        chomp($password = <STDIN>);
    }

    my %form;
    $form{name} = $username;
    $form{password} = $password;

    my $r; # Response.
    if ($cmd_opt{S}) {
        my $diary_url = "$hatena_url/$username/";

        $form{backurl} = $diary_url;
        $form{mode} = "enter";
        if ($cmd_opt{c}) {
            $form{persistent} = "1";
        }

        print_message("Login to $hatena_sslregister_url as $form{name}.");

        $r = $user_agent->simple_request(
            HTTP::Request::Common::POST("$hatena_sslregister_url", \%form)
        );

        print_debug("login: " . $r->status_line);

        print_debug("login: \$r = " . $r->content());
    } else {
        # For older version.

        print_message("Login to $hatena_url as $form{name}.");
        $r = $user_agent->simple_request(
            HTTP::Request::Common::POST("$hatena_url/login", \%form)
        );

        print_debug("login: " . $r->status_line);

        if (not $r->is_redirect) {
            error_exit("Login: Unexpected response: ", $r->status_line);
        }
    }

    print_message("Login OK.");

    print_debug("login: Making cookie jar.");

    $cookie_jar = HTTP::Cookies->new;
    $cookie_jar->extract_cookies($r);
    $cookie_jar->save($cookie_file);
    $cookie_jar->scan(\&get_rkm);

    print_debug("login: \$cookie_jar = " . $cookie_jar->as_string);
}

# get session id.
sub get_rkm($$$$$$$$$$$) {
    my ($version, $key, $val) = @_;
    if ($key eq 'rk') {
        $rkm = md5_base64($val);
        print_debug("get_rkm: \$rkm = " . $rkm);
    }
}

# Logout.
sub logout() {
    return unless $user_agent;

    # If "cookie" flag is on, and cookie file exists, do not logout.
    if ($cmd_opt{c} and -e($cookie_file)) {
        print_message("Skip logout.");
        return;
    }

    my %form;
    $form{name} = $username;
    $form{password} = $password;

    print_message("Logout from $hatena_url as $form{name}.");

    $user_agent->cookie_jar($cookie_jar);
    my $r = $user_agent->get("$hatena_url/logout");
    print_debug("logout: " . $r->status_line);

    if (not $r->is_redirect and not $r->is_success) {
        error_exit("Logout: Unexpected response: ", $r->status_line);
    }

    unlink($cookie_file);

    print_message("Logout OK.");
}

# Update entry.
sub update_diary_entry($$$$$$) {
    my ($year, $month, $day, $title, $body, $imgfile) = @_;

    if ($cmd_opt{t}) {
        # clear existing entry. if the entry does not exist, it has no effect.
        doit_and_retry("update_diary_entry: CLEAR.", sub { return post_it($year, $month, $day, "", "", "") });
    }

    # Make empty entry before posting.
    doit_and_retry("update_diary_entry: CREATE.", sub { return create_it($year, $month, $day) });

    # Post.
    doit_and_retry("update_diary_entry: POST.", sub { return post_it($year, $month, $day, $title, $body, $imgfile) });
}

# Delete entry.
sub delete_diary_entry($) {
    my ($date) = @_;

    # Delete.
    doit_and_retry("delete_diary_entry: DELETE.", sub { return delete_it($date) });
}

# Do the $funcref, and retry if fail.
sub doit_and_retry($$) {
    my ($msg, $funcref) = @_;
    my $retry = 0;
    my $ok = 0;

    while ($retry < 2) {
        $ok = $funcref->();
        if ($ok or not $cmd_opt{c}) {
            last;
        }
        print_debug("try_it: $msg");
        unlink($cookie_file);
        print_message("Old cookie. Retry login.");
        login();
        $retry++;
    }

    if (not $ok) {
        error_exit("try_it: Check username/password.");
    }
}

# Delete.
sub delete_it($) {
    my ($date) = @_;

    print_debug("delete_it: $date");

    $user_agent->cookie_jar($cookie_jar);

    my $r = $user_agent->simple_request(
        HTTP::Request::Common::POST("$hatena_url/$username/edit",
            # Content_Type => 'form-data',
            Content => [
                mode => "delete",
                date => $date,
                rkm => $rkm,
            ]
        )
    );

    print_debug("delete_it: " . $r->status_line);

    if ((not $r->is_redirect()) and (not $r->is_success())) {
        error_exit("Delete: Unexpected response: ", $r->status_line);
    }

    print_debug("delete_it: Location: " . $r->header("Location"));

    # Check the result. ERROR if the location ends with the date.
    # (Note that delete error != post error)
    if ($r->header("Location") =~ m(/$date$)) {
        print_debug("delete_it: returns 0 (ERROR).");
        return 0;
    } else {
        print_debug("delete_it: returns 1 (OK).");
        return 1;
    }
}

sub create_it($$$) {
    my ($year, $month, $day) = @_;

    print_debug("create_it: $year-$month-$day.");

    $user_agent->cookie_jar($cookie_jar);

    my $r = $user_agent->simple_request(
        HTTP::Request::Common::POST("$hatena_url/$username/edit",
            Content_Type => 'form-data',
            Content => [
                mode => "enter",
                timestamp => get_timestamp,
                year => $year,
                month => $month,
                day => $day,
                trivial => $cmd_opt{t},
                rkm => $rkm,

                # Important:
                # If (entry does exists) { append empty string (i.e. nop) }
                # If (entry does not exist) { create empty entry }
                title => "",
                body => "",
                date => "",
            ]
        )
    );

    print_debug("create_it: " . $r->status_line);

    if ((not $r->is_redirect()) and (not $r->is_success())) {
        error_exit("Create: Unexpected response: ", $r->status_line);
    }

    print_debug("create_it: Location: " . $r->header("Location"));

    # Check the result. OK if the location ends with the date.
    if ($r->header("Location") =~ m(/$year$month$day$)) {
        print_debug("create_it: returns 1 (OK).");
        return 1;
    } else {
        print_debug("create_it: returns 0 (ERROR).");

        return 0;
    }
}

sub post_it($$$$$$) {
    my ($year, $month, $day, $title, $body, $imgfile) = @_;

    print_debug("post_it: $year-$month-$day.");

    $user_agent->cookie_jar($cookie_jar);

    my $r = $user_agent->simple_request(
        HTTP::Request::Common::POST("$hatena_url/$username/edit",
            Content_Type => 'form-data',
            Content => [
                mode => "enter",
                timestamp => get_timestamp,
                year => $year,
                month => $month,
                day => $day,
                title => $title,
                trivial => $cmd_opt{t},
                rkm => $rkm,

                # Important:
                # This entry must already exist.
                body => $body,
                date => "$year$month$day",
                image => [
                    $imgfile,
                ]
            ]
        )
    );

    print_debug("post_it: " . $r->status_line);

    if (not $r->is_redirect) {
        error_exit("Post: Unexpected response: ", $r->status_line);
    }

    print_debug("post_it: Location: " . $r->header("Location"));

    # Check the result. OK if the location ends with the date.
    if ($r->header("Location") =~ m(/$year$month$day$)) {
        print_debug("post_it: returns 1 (OK).");
        return 1;
    } else {
        print_debug("post_it: returns 0 (ERROR).");
        return 0;
    }
}

# Get "YYYYMMDDhhmmss" for now.
sub get_timestamp() {
    my (@week) = qw(Sun Mon Tue Wed Thu Fri Sat);
    my ($sec, $min, $hour, $day, $mon, $year, $weekday) = localtime(time);
    $year += 1900;
    $mon++;
    $mon = "0$mon" if $mon < 10;
    $day = "0$day" if $day < 10;
    $hour = "0$hour" if $hour < 10;
    $min = "0$min" if $min < 10;
    $sec = "0$sec" if $sec < 10;
    $weekday = $week[$weekday];
    return "$year$mon$day$hour$min$sec";
}

# Show version message. This is called by getopts.
sub VERSION_MESSAGE {
    print <<"EOD";
Hatena Diary Writer Version $VERSION
Copyright (C) 2004,2005 by Hiroshi Yuki.
EOD
}

# Debug print.
sub print_debug(@) {
    if ($cmd_opt{d}) {
        print "DEBUG: ", @_, "\n";
    }
}

# Print message.
sub print_message(@) {
    print @_, "\n";
}

# Error exit.
sub error_exit(@) {
    print "ERROR: ", @_, "\n";
    unlink($cookie_file);
    exit(1);
}

# Read title and body.
sub read_title_body($) {
    my ($file) = @_;

    # Execute filter command, if any.
    my $input = $file;
    if ($filter_command) {
        $input = sprintf("$filter_command |", $file);
    }
    print_debug("read_title_body: input: $input");
    if (not open(FILE, $input)) {
        error_exit("$!:$input");
    }
    my $title = <FILE>; # first line.
    chomp($title);
    my $body = join('', <FILE>); # rest of all.
    close(FILE);

    # Convert encodings.
    if ($enable_encode and ($client_encoding ne $server_encoding)) {
        print_debug("Convert from $client_encoding to $server_encoding.");
        Encode::from_to($title, $client_encoding, $server_encoding);
        Encode::from_to($body, $client_encoding, $server_encoding);
    }

    return($title, $body);
}

# Find image file.
sub find_image_file($) {
    my ($fulltxt) = @_;
    my ($base, $path, $type) = fileparse($fulltxt, qr/\.txt/);
    for my $ext ('jpg', 'png', 'gif') {
        my $imgfile = "$path$base.$ext";
        if (-e $imgfile) {
            if ($cmd_opt{f}) {
                print_debug("find_image_file: -f option, always update: $imgfile");
                return $imgfile;
            } elsif (-e($touch_file) and (-M($imgfile) > -M($touch_file))) {
                print_debug("find_image_file: skip $imgfile (not updated).");
                next;
            } else {
                print_debug("find_image_file: $imgfile");
                return $imgfile;
            }
        }
    }
    return undef;
}

# Replace "*t*" with timestamp.
sub replace_timestamp($) {
    my ($filename) = @_;

    # Read.
    open(FILE, $filename) or error_exit("$!: $filename");
    my $file = join('', <FILE>);
    close(FILE);

    # Replace.
    my $newfile = $file;
    $newfile =~ s/^\*t\*/"*" . time() . "*"/gem;

    # Write if replaced.
    if ($newfile ne $file) {
        print_debug("replace_timestamp: $filename");
        open(FILE, "> $filename") or error_exit("$!: $filename");
        print FILE $newfile;
        close(FILE);
    }
}

# Show help message. This is called by getopts.
sub HELP_MESSAGE {
    print <<"EOD";

Usage: perl $0 [Options]

Options:
    --version       Show version.
    --help          Show this message.
    -t              Trivial. Use this switch for trivial edit (i.e. typo).
    -d              Debug. Use this switch for verbose log.
    -u username     Username. Specify username.
    -p password     Password. Specify password.
    -a agent        User agent. Default value is HatenaDiaryWriter/$VERSION.
    -T seconds      Timeout. Default value is 180.
    -c              Cookie. Skip login/logout if $cookie_file exists.
    -g groupname    Groupname. Specify groupname.
    -f filename     File. Send only this file without checking timestamp.
    -M              Do NOT replace *t* with current time.
    -n config_file  Config file. Default value is $config_file.

Config file example:
#
# $config_file
#
id:yourid
password:yourpassword
cookie:cookie.txt
# txt_dir:/usr/yourid/diary
# touch:/usr/yourid/diary/hw.touch
# proxy:http://www.example.com:8080/
# g:yourgroup
# client_encoding:Shift_JIS
# server_encoding:UTF-8
## for Unix, if Encode module is not available.
# filter:iconv -f euc-jp -t utf-8 %s
EOD
}

# Load config file.
sub load_config() {
    print_debug("Loading config file ($config_file).");
    if (not open(CONF, $config_file)) {
        error_exit("Can't open $config_file.");
    }
    while (<CONF>) {
        chomp;
        if (/^\#/) {
            # skip comment.
        } elsif (/^$/) {
            # skip blank line.
        } elsif (/^id:([^:]+)$/) {
            $username = $1;
            print_debug("load_config: id:$username");
        } elsif (/^g:([^:]+)$/) {
            $groupname = $1;
            print_debug("load_config: g:$groupname");
        } elsif (/^password:(.*)$/) {
            $password = $1;
            print_debug("load_config: password:********");
        } elsif (/^cookie:(.*)$/) {
            $cookie_file = glob($1);
            $cmd_opt{c} = 1; # If cookie file is specified, Assume '-c' is given.
            print_debug("load_config: cookie:$cookie_file");
        } elsif (/^proxy:(.*)$/) {
            $http_proxy = $1;
            print_debug("load_config: proxy:$http_proxy");
        } elsif (/^client_encoding:(.*)$/) {
            $client_encoding = $1;
            print_debug("load_config: client_encoding:$client_encoding");
        } elsif (/^server_encoding:(.*)$/) {
            $server_encoding = $1;
            print_debug("load_config: server_encoding:$server_encoding");
        } elsif (/^filter:(.*)$/) {
            $filter_command = $1;
            print_debug("load_config: filter:$filter_command");
        } elsif (/^txt_dir:(.*)$/) {
            $txt_dir = glob($1);
            print_debug("load_config: txt_dir:$txt_dir");
        } elsif (/^touch:(.*)$/) {
            $touch_file = glob($1);
            print_debug("load_config: touch:$touch_file");
        } else {
            error_exit("Unknown command '$_' in $config_file.");
        }
    }
    close(CONF);
}
__END__
