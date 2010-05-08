$|=1;

package bmwqemu;
use strict;
use warnings;
use Time::HiRes qw(sleep);
use Digest::MD5;
use Exporter;
use ppm;
use threads;
use threads::shared;
my $goodimageseen :shared = 0;
my $endreadingcon :shared = 0;
my $lastname;
my $lastknowninststage :shared = "";

our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA = qw(Exporter);
@EXPORT = qw($qemubin $qemupid %cmd 
&qemusend &sendkey &sendautotype &autotype &take_screenshot &qemualive &waitidle &waitgoodimage &waitinststage &open_management_console &close_management_console);


our $debug=1;
our $qemubin="/usr/bin/kvm";
our $qemupid;
our $managementcon;
our %cmd=qw(
next alt-n
install alt-i
finish alt-f
accept alt-a
createpartsetup alt-c
custompart alt-c
addpart alt-d
donotformat alt-d
addraid alt-i
add alt-a
raid0 alt-0
raid1 alt-1
raid6 alt-6
raid10 alt-i
mountpoint alt-m
filesystem alt-s
acceptlicense alt-a
instdetails alt-d
rebootnow alt-n
);


$ENV{INSTLANG}||="us";
if($ENV{INSTLANG} eq "de") {
	$cmd{"next"}="alt-w";
	$cmd{"createpartsetup"}="alt-e";
	$cmd{"custompart"}="alt-b";
	$cmd{"addpart"}="alt-h";
	$cmd{"finish"}="alt-b";
	$cmd{"accept"}="alt-r";
	$cmd{"donotformat"}="alt-n";
	$cmd{"add"}="alt-h";
	$cmd{"raid6"}="alt-d";
	$cmd{"raid10"}="alt-r";
	$cmd{"mountpoint"}="alt-e";
	$cmd{"rebootnow"}="alt-j";
}


sub diag($)
{ print LOG "@_\n"; return unless $debug; print STDERR "@_\n";}

sub mydie($)
{ kill(15, $qemupid); diag "@_"; close LOG; sleep 1 ; exit 1; }

sub fileContent($) {my($fn)=@_;
	open(my $fd, $fn) or return undef;
	local $/;
	my $result=<$fd>;
	close($fd);
	return $result;
}

sub qemusend($)
{
	print LOG "qemusend: $_[0]\n";
	print shift(@_)."\n";
}

sub sendkey($)
{
	my $key=shift;
	qemusend "sendkey $key";
	sleep(0.25);
}

my %charmap=("."=>"dot", "/"=>"slash", "="=>"equal", "-"=>"minus", "_"=>"shift-minus",
   "\t"=>"tab", "\n"=>"ret", " "=>"spc", "\b"=>"backspace", "\e"=>"esc");
for my $c ("A".."Z") {$charmap{$c}="shift-\L$c"}


sub sendautotype($)
{
	my $string=shift;
	foreach my $letter (split("", $string)) {
		if($charmap{$letter}) { $letter=$charmap{$letter} }
		sendkey $letter;
	}
}

sub autotype($)
{
	my $string=shift;
	my $result="";
	foreach my $letter (split("", $string)) {
		$result.="sendkey $letter\n";
	}
	return $result;
}

my $lasttime;
my $n=0;
my %md5file;
our %md5badlist=qw();
our %md5goodlist;
our %md5inststage;
eval(fileContent("goodimage.pm"));
my $readconthread;

# input: ref on PPM data
sub inststagedetect($)
{ my $dataref=shift;
	return if length($$dataref)!=1440015; # only work on images of 800x600
	my $ppm=ppm->new($$dataref);
	my @md5=();
	# use several relevant non-text parts of the screen to look them up up
	# WARNING: some break when background/theme changes (%md5inststage needs updating)
	my $ppm2;
	# popup text detector
	$ppm2=$ppm->copyrect(230,230, 300,100);
	$ppm2->threshold(0x80); # black/white => drop most background
	push(@md5, Digest::MD5::md5_hex($ppm2->{data}));
	# use header text for GNOME
	$ppm2=$ppm->copyrect(0,0, 250,30);
	$ppm2->threshold(0x80); # black/white => drop most background
	push(@md5, Digest::MD5::md5_hex($ppm2->{data}));
	# KDE/NET/DVD detect checks on left
	$ppm2=$ppm->copyrect(27,128,13,250);
	$ppm2->replacerect(0,137,13,13); # mask out text
	$ppm2->replacerect(0,215,13,13); # mask out text
	push(@md5, Digest::MD5::md5_hex($ppm2->{data}));
	$ppm2->threshold(0x80); # black/white => drop most background
	push(@md5, Digest::MD5::md5_hex($ppm2->{data}));

	foreach my $md5 (@md5) {
		my $currentinststage=$md5inststage{$md5}||"";
		if($currentinststage) { $lastknowninststage=$currentinststage }
		diag "stage=$currentinststage $md5";
		last if($currentinststage); # stop on first match - so must put most specific tests first
	}
}

sub take_screenshot()
{
	my $path="qemuscreenshot/";
	mkdir $path;
	if($lastname && -e $lastname) { # processing previous image, because saving takes time
		# hardlinking identical files saves space
		my $data=fileContent($lastname);
		my $md5=Digest::MD5::md5_hex($data);
		if($md5badlist{$md5}) {diag "error condition detected. test failed. see $lastname"; sleep 1; mydie "bad image seen"}
		diag("md5=$md5 laststage=$lastknowninststage");
		if($md5goodlist{$md5}) {$goodimageseen=1; diag "good image"}
		# ignore bottom 15 lines (blinking cursor, animated mouse-pointer)
		if(length($data)==1440015) {$md5=Digest::MD5::md5(substr($data,15,800*3*(600-15)))}
		if($md5file{$md5}) { # old
			unlink($lastname); # warning: will break if FS does not support hardlinking
			link($md5file{$md5}->[0], $lastname);
			my $linkcount=$md5file{$md5}->[1]++;
			#my $linkcount=(stat($lastname))[3]; # relies on FS
			if($linkcount>530) {mydie "standstill detected. test ended. see $lastname\n"} # above 120s of autoreboot
		} else { # new
			$md5file{$md5}=[$lastname,1];
			inststagedetect(\$data);
		}
	}
	my $now=time();
	if(!$lasttime || $lasttime!=$now) {$n=0};
	my $filename=$path.$now."-".$n++.".ppm";
	#print STDERR $filename,"\n";
	qemusend "screendump $filename";
	$lastname=$filename;
	$lasttime=$now;
}

sub qemualive()
{ 
#	if(!$qemupid) {$qemupid=`pidof -s $qemubin`; chomp $qemupid;}
	return 0 unless $qemupid;
	kill 0, $qemupid;
}

sub waitidle(;$)
{
	my $timeout=shift||19;
	my $prev;
	diag "waitidle(timeout=$timeout)";
	for my $n (1..$timeout) {
		my $stat=fileContent("/proc/$qemupid/stat");
			#"/proc/$qemupid/schedstat");
		my @a=split(" ", $stat);
		$stat=$a[13];
		next unless $stat;
		#$stat=$a[1];
		if($prev) {
			my $diff=$stat-$prev;
			if($diff<10) { # idle for one sec
			#if($diff<2000000) # idle for one sec
				diag "idle detected";
				return 1;
			}
		}
		$prev=$stat;
		sleep 1;
	}
	diag "waitidle timed out";
	return 0;
}

sub waitgoodimage(;$)
{
	my $timeout=shift||10;
	$goodimageseen=0;
	diag "waiting for good image(timeout=$timeout)";
	for my $n (1..$timeout) {
		if($goodimageseen) {diag "seen good image... continuing execution"; return 1;}
		sleep 1;
	}
	diag "waitgoodimage timed out";
	return 0;
}

sub waitinststage($;$)
{
	my $stage=shift;
	my $timeout=shift||30;
	diag "start waiting $timeout seconds for stage=$stage";
	for my $n (1..$timeout) {
		if($stage eq $lastknowninststage) {diag "detected stage=$stage ... continuing execution"; sleep 3; return 1;}
		sleep 1;
	}
	diag "waitinststage stage=$stage timed out after $timeout";
	return 0;
}


use IO::Socket;
use threads;

# read all output from management console and forward it to STDOUT
sub readconloop
{
	$|=1;
	while(<$managementcon>) {
		print $_;
		last if($endreadingcon);
	}
	diag "exiting management console read loop";
}

sub open_management_console()
{
	open(LOG, ">", "currentautoinst-log.txt");
	# set unbuffered so that sendkey lines from main thread will be written
	my $oldfh=select(LOG); $|=1; select($oldfh);

	$managementcon=IO::Socket::INET->new("localhost:15222") or mydie "error opening management console: $!";
	$endreadingcon=0;
	$readconthread=threads->create(\&readconloop); # without this, qemu will block
	select $managementcon;
	$|=1; # autoflush
	$managementcon;
}

sub close_management_console()
{
	$endreadingcon=1;
	qemusend "";
	close $managementcon;
	$readconthread->join();
}

1;
