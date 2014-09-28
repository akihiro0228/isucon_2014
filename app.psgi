use lib qw/lib/;
use Plack::Builder;
use Isu4Qualifier::Web;
use Plack::Session::State::Cookie;
use Plack::Session::Store::File;

my $app = Isu4Qualifier::Web->psgi();
builder {
  enable 'ReverseProxy';
  enable 'Session',
    state => Plack::Session::State::Cookie->new(
      httponly    => 1,
      session_key => "isu4_session",
    ),
    store => Plack::Session::Store::File->new(
      dir         => "/tmp/isu4_session_plack",
    ),
    ;
  $app;
};
