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

=head1 NAME

Plack::Middleware::StackTrace - Displays stack trace when your app dies

=head1 SYNOPSIS

  enable "StackTrace";

=head1 DESCRIPTION

This middleware catches exceptions (run-time errors) happening in your
application and displays nice stack trace screen.

This middleware is enabled by default when you run L<plackup> in the
default I<development> mode.

You're recommended to use this middleware during the development and
use L<Plack::Middleware::HTTPExceptions> in the deployment mode as a
replacement, so that all the exceptions thrown from your application
still get caught and rendered as a 500 error response, rather than
crashing the web server.

Catching errors in streaming response is not supported.

=head1 CONFIGURATION

=over 4

=item force

  enable "StackTrace", force => 1;

Force display the stack trace when an error occurs within your
application and the response code from your application is
500. Defaults to off.

The use case of this option is that when your framework catches all
the exceptions in the main handler and returns all failures in your
code as a normal 500 PSGI error response. In such cases, this
middleware would never have a chance to display errors because it
can't tell if it's an application error or just random C<eval> in your
code. This option enforces the middleware to display stack trace even
if it's not the direct error thrown by the application.

=item no_print_errors

  enable "StackTrace", no_print_errors => 1;

Skips printing the text stacktrace to console
(C<psgi.errors>). Defaults to 0, which means the text version of the
stack trace error is printed to the errors handle, which usually is a
standard error.

=back

=head1 AUTHOR

Tokuhiro Matsuno

Tatsuhiko Miyagawa

=head1 SEE ALSO

L<Devel::StackTrace::AsHTML> L<Plack::Middleware> L<Plack::Middleware::HTTPExceptions>

=cut

