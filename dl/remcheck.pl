#!/usr/bin/perl

require "../latest.pm";
require "stuff.pm";

# get database
$db=new pbase;
$db->open($databasefilename);

my $mod; # number of changes made

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
    gmtime(time);
my $logfile = sprintf("log/remcheck-%04d%02d%02d-%02d%02d%02d.log",
                      $year+1900, $mon+1, $mday, $hour, $min, $sec);

# open and close each time to allow removal at any time
sub logmsg {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
        gmtime(time);
    open(FTPLOG, ">>$logfile");
    printf FTPLOG ("%02d:%02d:%02d ", $hour, $min, $sec);
    print FTPLOG @_;
    close(FTPLOG);
    print @_;
}

&latest::scanstatus();

@all = $db->find_all("typ"=>"^entry\$");

logmsg "\$version = $latest::headver\n";
logmsg sprintf("%d packages found in database\n", scalar(@all));
logmsg "All times in this log is GMT/UTC\n";
my $version = $latest::headver;

sub show {
    my ($t)=@_;
    if($t eq "-") {
        return "";
    }
    return $t;
}

sub getlast5versions {
    my @five;
    my $per;
    for $per ($db->find_all()) {
        my $val=$$per{'curl'};
        $hash{$val}=1;
    }
    
    sub numit {
        my ($str)=@_;
        my @p=split(/\./, $str);
        
        return $p[0]*1000 + $p[1]*100 + $p[2];
    }
    
    sub sortit {
        return numit($a) <=> numit($b);
    }
    
    my $c;
    for(reverse sort sortit keys %hash) {
        push @five, $_;
        if($c++ >= 5) {
            last;
        }
    }
    return @five;
}

#print getlast5versions();

# a hash with arrays (url => url contents)
my %urlhash;
sub geturl {
    my $curlcmd="curl -fsm20 --compressed";

    my ($url) = @_;

    if($urlhash{$url}) {
        # return the array
        logmsg " URL contents CACHED, no need to fetch again\n";
        return @{$urlhash{$url}};
    }
    my @content = `$curlcmd \"$url\"`;
    if(@content) {
        # store the content in the hash
        @{$urlhash{$url}}=@content;
    }
    return @content;
}

my $update=0;
my $uptodate=0;
my $missing=0;
my $ref;
for $ref (@all) {
    my $inurl = $$ref{'churl'};
    my $chregex = $$ref{'chregex'};
    my $churl = $inurl;
    my $osversion = $$ref{'osver'};
    my $fixedver;

    my $s = $$ref{'os'};

    if($s eq "-") {
        $s = "Generic";
    }
    logmsg sprintf("===> Package: %s %s %s %s %s by %s\n",
                   $s,
                   show($$ref{'osver'}),
                   show($$ref{'cpu'}),
                   show($$ref{'flav'}),
                   show($$ref{'pack'}),
                   $$ref{'name'} );
    logmsg sprintf " Modify: http://curl.haxx.se/dl/mod_entry.cgi?__id=%s\n",
    $$ref{'__id'};


    if($churl) {
        # there's a URL to check

        # first unescape HTML encoding
        $churl = CGI::unescapeHTML($churl);

        logmsg " Check URL: \"$churl\"\n";

        # expand $version!
        if($churl =~ s/\$version/$version/g) {
            # 'fixedver' means that we have the version number in the URL
            # and thus success means this version exists
            $fixedver=1;
        }
        $churl =~ s/\$osversion/$osversion/g;

        logmsg " Used URL: \"$churl\"\n";
        my @data = geturl($churl);

        if($chregex) {
            if(!$data[0]) {
                logmsg " $churl failed, no such URL or dead for now\n";
                next;
            }

            # there's a regex to check for in the downloaded page
            $chregex = CGI::unescapeHTML($chregex);

            logmsg " Scan for regex \"$chregex\"\n";

            # replace variables in the regex too
            $chregex =~ s/\$version/$ver/g;
            $chregex =~ s/\$osversion/$osversion/g;

            logmsg " Use regex \"$chregex\"\n";
            #$chregex = quotemeta($chregex);
            my $l;
            my $match;
            for $l (@data) {
              #  print "$l\n";
                if($l =~ /$chregex/) {
                    my $r = $1;
                    if($fixedver) {
                        # '$version' was part of the URL and thus we don't
                        # need/want to extract it from the regex match
                        $r = $version;
                    }
                    $match++;
                    logmsg " Remote version found: $r\n";
                    logmsg sprintf " Present database version: %s\n",
                    $$ref{'curl'};

                    if($$ref{'curl'} ne $r) {
                        # TODO: actually store the new version here
                        $update++;
                    }
                    else {
                        $uptodate++;
                        logmsg " NOT updated\n";
                    }
                    last;
                }
            }
            logmsg " NO line matched the regex!\n" if(!$match);
        }
        else {
            # store version as of now
            my $ver = $version;

            if($fixedver) {
                #
                # Only scan for older URLs if the $version is part of it
                #

                my @five = getlast5versions();

                shift @five; # we already tried the latest

                # while no data was received, try older versions
                while(!$data[0] && @five) {
                    $ver = shift @five;
                    $churl = $inurl;
                    $churl =~ s/\$version/$ver/g;
                    $churl =~ s/\$osversion/$osversion/g;
                    
                    logmsg " Retry with version $ver: \"$churl\"\n";
                    my @data = geturl($churl);
                }
            }

            if(!$data[0]) {
                logmsg " None of the 5 latest versions found!\n";
                logmsg " NOT updated\n";
                next;
            }

            logmsg " Remote version found: $ver\n";
            logmsg sprintf " Present database version: %s\n", $$ref{'curl'};
            if($$ref{'curl'} ne $version) {
                # TODO: actually store the new version here
                $update++;
            }
            else {
                $uptodate++;
                logmsg " NOT updated\n";
            }
        }
    }
    else {
        $missing++;
    }
}

logmsg "SUMMARY:\n$update packages found up-to-date\n";

if($missing) {
    logmsg "$missing listed packages lacked autocheck URL\n";
}

if($update) {
    # one or more updated entries, save!
    #$db->save();
    logmsg "$update changes saved\n";
}
else {
    logmsg "Nothing was updated\n";
}