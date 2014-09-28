use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Isu4Qualifier::Web;
use Plack::Session::State::Cookie;
use Plack::Session::Store::File;
use DateTime;

my $root_dir = File::Basename::dirname(__FILE__);
my $session_dir = "/tmp/isu4_session_plack";
mkdir $session_dir;

my $tz = DateTime::TimeZone->new( name => 'Asia/Tokyo' );
my $now = DateTime->now(time_zone => $tz);

my $app = Isu4Qualifier::Web->psgi($root_dir);
builder {
#  enable "Profiler::NYTProf",
#    env_nytprof          => 'start=no:addpid=0:blocks=0:slowops=0:file=/tmp/nytprof/profile.out',
#    env_nytprof => 'sigexit=int,hup,term:savesrc=0:start=no:stmts=0',
#    profiling_result_dir => sub { '/tmp/nytprof/' },
#    profiling_result_file_name => sub { "nytprof.".$$.".".$now->strftime('%Y%m%d%H%M%S').".out"; },
#    enable_profile       => sub { 1 },
#    enable_reporting     => 1,
#    report_dir	         => sub { '/tmp/report' }
#    ;
  enable 'ReverseProxy';
  enable 'Static',
    path => qr!^/(?:stylesheets|images)/!,
    root => $root_dir . '/public';
  enable 'Session',
    state => Plack::Session::State::Cookie->new(
      httponly    => 1,
      session_key => "isu4_session",
    ),
    store => Plack::Session::Store::File->new(
      dir         => $session_dir,
    ),
    ;
  $app;
};
