package Plack::Middleware::StreamingSession;

use strict;
use warnings;

use Data::Dumper;
use Plack::Request;
use Plack::Session::State::Cookie;
use SimpleStore::Object;

use parent qw/Plack::Middleware/;

use constant DEBUG => 0;

sub prepare_app {
    my $self = shift;

    unless ($self->{key}) { $self->{key} = "ssessionkey"; }
    unless ($self->{ssdir}) { $self->{ssdir} = "/tmp"; }

    $self->{store} = SimpleStore::Object->new($self->{ssdir});

    warn("key is $self->{key}") if DEBUG;

    $self->{cookie_extractor} = Plack::Session::State::Cookie->new( session_key => $self->{key} );
}

sub call {
    my ($self, $env) = @_;

    warn("entering StreamingSession::call") if DEBUG;

    # FIXME make short-circuit paths part of instantiation options
    if ($env->{PATH_INFO} eq "/favicon.ico") {
        return sub { my $respond = shift; $respond->(); }
    }

    return sub {
        my $respond = shift;
        warn("entering StreamingSession::call callback") if DEBUG;

        $self->get_session($env, sub {
            my ($session, $id) = @_;

	        if ($id && $session) {
	            warn("pulled session $id from state (cookie)") if DEBUG;
	            $env->{'psgix.session'} = $session;
	         } else {
	            $id = $self->{cookie_extractor}->generate($env);
	            warn("id is $id here") if DEBUG;
	            $env->{'psgix.session'} = {};
	        }
	
	        # stick the session hash into the environment to pass to the app
	        $env->{'psgix.session'} = $session;
	        $env->{'psgix.session.options'} = { id => $id };
	
	        warn("modified environment to add session id.") if DEBUG;
	
	        my $res = $self->app->($env);
	        warn("pulled res cb from app, its ref is " . ref $res) if DEBUG;
	
	        if (ref $res eq 'ARRAY') {
	            warn("called with array");
	            die("StreamingSession works only in a streaming configuration. Please use any other session module.");
	        }
	
            $res->(sub {
                # this is what our app calls when it's done,
                # so it's our chance to munge the headers as we see fit
                $self->finalize($env, $_[0], sub { $respond->(@_) } );
            });

        });
    };
}

# stolen
sub finalize {
    my($self, $env, $res, $cb) = @_;

    my $session = $env->{'psgix.session'};
    my $options = $env->{'psgix.session.options'};

    my $finalize_cookie = sub {
        if ($options->{expire}) {
            # $self->expire_session($options->{id}, $res, $env);
            $self->{cookie_extractor}->expire_session_id($options->{id}, $res, $env->{'psgix.session.options'});
        } else {
            #$self->save_state($options->{id}, $res, $env);
            $self->{cookie_extractor}->finalize($options->{id}, $res, $env->{'psgix.session.options'});
        }

        $cb->($res);
    };

    # the store!
    if ($options->{no_store}) {
        $finalize_cookie->();
    } else {
        $self->commit($env, sub {
            $finalize_cookie->();
        });
    }

}

sub commit {
    my ($self, $env, $cb) = @_;

    my $session = $env->{'psgix.session'};
    my $options = $env->{'psgix.session.options'};
    my $id = $options->{id};

    warn("in ssession::commit for $id") if DEBUG;
    if ($options->{expire}) {
        $self->{store}->delete($id, $cb);
    } else {
        $self->{store}->set($id, $session, $cb);
    }
}

sub get_session {
    my ($self, $env, $cb) = @_;

    # the CPAN modules break this in to two steps-
    # _extract_ ID from "state" (cookie or params)
    # _fetch_ from store (memory or disk)

    # we're going to use CPAN's cookie-based "state" mechanism, since it's
    # nonblocking already. then we'll implement our own "store" that will 
    # be nonblocking
    my $id = $self->{cookie_extractor}->extract($env);
    warn("session id $id") if DEBUG;

    $self->fetch($id, sub {
        my $s = shift;
        warn("session fetched") if DEBUG;
        warn(Dumper $s) if DEBUG;
        if (not(defined($s))) { $s = {}; }
        $cb->($s, $id);
    });
}

sub fetch {
    my ($self, $id, $cb) = @_;

    $self->{store}->get($id, $cb);
}

1;

__END__

