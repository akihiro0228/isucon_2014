package Isu4Qualifier::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use Digest::SHA qw/ sha256_hex /;
use Data::Dumper;


sub config {
  my ($self) = @_;
  $self->{_config} ||= {
    user_lock_threshold => 3,
    ip_ban_threshold    => 10
  };
};

sub db {
  my ($self) = @_;

  unless ($self->{_db}) {
    $self->{_db} = DBIx::Sunny->connect(
      "dbi:mysql:database=isu4_qualifier;host=localhost;port=3306", 'root', ''
    );
  }

  $self->{_db}
}

sub calculate_password_hash {
  my ($password, $salt) = @_;
  sha256_hex($password . ':' . $salt);
};

sub user_locked {
  my ($self, $user) = @_;
  my $log = $self->db->select_row(
    'SELECT COUNT(*) AS failures FROM login_log WHERE user_id = ? AND id > IFNULL((select id from login_log where user_id = ? AND succeeded = 1 ORDER BY id DESC LIMIT 1), 0)',
    $user->{'id'}, $user->{'id'});

  $self->config->{user_lock_threshold} <= $log->{failures};
};

sub ip_banned {
  my ($self, $ip) = @_;
  my $log = $self->db->select_row(
    'SELECT COUNT(*) AS failures FROM login_log WHERE ip = ? AND id > IFNULL((select id from login_log where ip = ? AND succeeded = 1 ORDER BY id DESC LIMIT 1), 0)',
    $ip, $ip);

  $self->config->{ip_ban_threshold} <= $log->{failures};
};

sub attempt_login {
  my ($self, $login, $password, $ip) = @_;
  my $user = $self->db->select_row('SELECT * FROM users WHERE login = ?', $login);

  unless ($user) {
    $self->login_log(0, $login, $ip);
    return undef, 'wrong_login';
  }

  # BAN チェック

  if ($self->ip_banned($ip)) {
    $self->login_log(0, $login, $ip, $user->{id});
    return undef, 'banned';
  }

  if ($self->user_locked($user)) {
    $self->login_log(0, $login, $ip, $user->{id});
    return undef, 'locked';
  }



  # OK!
  if (calculate_password_hash($password, $user->{salt}) eq $user->{password_hash}) {
    $self->login_log(1, $login, $ip, $user->{id});
    return $user, undef;
  }

  $self->login_log(0, $login, $ip, $user->{id});
  return undef, 'wrong_password';
};

sub current_user {
  my ($self, $user_id) = @_;

  $self->db->select_one('SELECT id FROM users WHERE id = ?', $user_id);
};

sub last_login {
  my ($self, $user_id) = @_;

  my $logs = $self->db->select_all(q{
SELECT
   created_at,  user_id, ip, succeeded, login
FROM 
  login_log
WHERE 
  succeeded = 1 AND user_id = ? 
ORDER BY 
  id DESC LIMIT 2
	},$user_id);

  @$logs[-1];
};

sub banned_ips {
  my ($self) = @_;
  my @ips;
  my $threshold = $self->config->{ip_ban_threshold};

  my $not_succeeded = $self->db->select_all(q{
SELECT
  ip 
FROM 
  (SELECT ip, MAX(succeeded) as max_succeeded, COUNT(*) as cnt FROM login_log GROUP BY ip) AS t0 
WHERE
  t0.max_succeeded = 0 AND t0.cnt >= ?
  }, $threshold);

  foreach my $row (@$not_succeeded) {
    push @ips, $row->{ip};
  }

  my $last_succeeds = $self->db->select_all(q{
SELECT 
  ip, MAX(id) AS last_login_id 
FROM 
  login_log
WHERE 
  succeeded = 1 
GROUP 
  by ip}
	);

  foreach my $row (@$last_succeeds) {
    my $count = $self->db->select_one(q{
SELECT 
  COUNT(*) AS cnt 
FROM 
  login_log 
WHERE 
  ip = ? AND ? < id
		}, $row->{ip}, $row->{last_login_id});

    if ($threshold <= $count) {
      push @ips, $row->{ip};
    }
  }

  \@ips;
};

sub locked_users {
  my ($self) = @_;
  my $threshold = $self->config->{user_lock_threshold};

  my $not_succeeded = $self->db->select_all(q{
SELECT
  user_id, login
FROM
  (SELECT user_id, login, MAX(succeeded) as max_succeeded, COUNT(*) as cnt FROM login_log GROUP BY user_id) AS t0
WHERE
  t0.user_id IS NOT NULL AND t0.max_succeeded = 0 AND t0.cnt >= ?
  }, $threshold);

  my @user_ids;
  foreach my $row (@$not_succeeded) {
    push @user_ids, $row->{login};
  }

  my $last_succeeds = $self->db->select_all(q{
SELECT
  user_id, login, MAX(id) AS last_login_id
FROM
  login_log
WHERE
  user_id IS NOT NULL AND succeeded = 1
GROUP BY user_id
  });

  foreach my $row (@$last_succeeds) {
    my $count = $self->db->select_one(q{
SELECT
  COUNT(*) AS cnt
FROM
  login_log
WHERE user_id = ? AND ? < id
  }, $row->{user_id}, $row->{last_login_id});
    if ($threshold <= $count) {
      push @user_ids, $row->{login};
    }
  }

  \@user_ids;
};

sub login_log {
  my ($self, $succeeded, $login, $ip, $user_id) = @_;
  $self->db->query(q{
INSERT INTO 
  login_log (`created_at`, `user_id`, `login`, `ip`, `succeeded`) 
VALUES 
  (NOW(),?,?,?,?)
  }, $user_id, $login, $ip, ($succeeded ? 1 : 0));
};

sub set_flash {
  my ($self, $c, $msg) = @_;
  $c->req->env->{'psgix.session'}->{flash} = $msg;
};

sub pop_flash {
  my ($self, $c, $msg) = @_;
  my $flash = $c->req->env->{'psgix.session'}->{flash};
  delete $c->req->env->{'psgix.session'}->{flash};
  $flash;
};

filter 'session' => sub {
  my ($app) = @_;
  sub {
    my ($self, $c) = @_;
    my $sid = $c->req->env->{'psgix.session.options'}->{id};
    $c->stash->{session_id} = $sid;
    $c->stash->{session}    = $c->req->env->{'psgix.session'};
    $app->($self, $c);
  };
};

get '/' => [qw(session)] => sub {
  my ($self, $c) = @_;

  $c->render('index.tx', { flash => $self->pop_flash($c) });
};

post '/login' => sub {
  my ($self, $c) = @_;

  my ($user, $err) = $self->attempt_login(
    $c->req->param('login'),
    $c->req->param('password'),
    $c->req->address
  );

  if ($user && $user->{id}) {
    $c->req->env->{'psgix.session'}->{user_id} = $user->{id};
    $c->redirect('/mypage');
  }
  else {
    if ($err eq 'locked') {
      $self->set_flash($c, 'This account is locked.');
    }
    elsif ($err eq 'banned') {
      $self->set_flash($c, "You're banned.");
    }
    else {
      $self->set_flash($c, 'Wrong username or password');
    }
    $c->redirect('/');
  }
};

get '/mypage' => [qw(session)] => sub {
  my ($self, $c) = @_;
  my $user_id = $c->req->env->{'psgix.session'}->{user_id};

  if ($self->current_user($user_id)) {
    $c->render('mypage.tx', { last_login => $self->last_login($user_id) });
  }
  else {
    $self->set_flash($c, "You must be logged in");
    $c->redirect('/');
  }
};

get '/report' => sub {
  my ($self, $c) = @_;
  $c->render_json({
    banned_ips => $self->banned_ips,
    locked_users => $self->locked_users,
  });
};

1;
