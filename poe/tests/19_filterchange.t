#!/usr/bin/perl -w
# $Id$

# Exercises filter changing.  A lot of this code comes from Philip
# Gwyn's filterchange.perl sample.

use strict;
use lib qw(./lib ../lib);

use TestSetup qw(ok not_ok results test_setup ok_if many_not_ok);
use MyOtherFreezer;
use TestPipe;

sub DEBUG () { 0 }

sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw( Wheel::ReadWrite Driver::SysRW
            Filter::Block Filter::Line Filter::Reference Filter::Stream
          );

# Showstopper here.  Try to build a pair of file handles.  This will
# try a pair of pipe()s and socketpair().  If neither succeeds, then
# all tests are skipped.  Try socketpair() first, so that both methods
# will be tested on my test platforms.

# Socketpair.  Read and write handles are the same.
my ($master_read, $master_write, $slave_read, $slave_write) = TestPipe->new();
unless (defined $master_read) {
  &test_setup(0, "could not create a pipe in any form");
}

# Set up tests, and go.
&test_setup(36);

### Skim down to PARTIAL BUFFER TESTS to find the partial buffer
### get_pending tests.  Those tests can run stand-alone without the
### event loop.

### Script for the master session.  This is a send/expect thing, but
### the expected responses are implied by the commands that are sent.
### Normal master operation is: (1) send the command; (2) get
### response; (3) switch our filter if we sent a "do".  Normal slave
### operation is: (1) get a command; (2) send response; (3) switch our
### filter if we got "do".

# Tests:
# (lin -> lin)  (lin -> str)  (lin -> ref)  (lin -> blo)
# (str -> lin)  (str -> str)  (str -> ref)  (str -> blo)
# (ref -> lin)  (ref -> str)  (ref -> ref)  (ref -> blo)
# (blo -> lin)  (blo -> str)  (blo -> ref)  (blo -> blo)

# Standard block size.  Things will be truncated or space-padded out
# to this size.
sub BLOCK_SIZE () { 128 }

# Symbolic constants for mode names, so we don't make typos.
sub LINE      () { 'line'      }
sub STREAM    () { 'stream'    }
sub REFERENCE () { 'reference' }
sub BLOCK     () { 'block'     }

# Commands to switch modes.
sub DL () { 'do ' . LINE      }
sub DS () { 'do ' . STREAM    }
sub DR () { 'do ' . REFERENCE }
sub DB () { 'do ' . BLOCK     }

# Script that drives the master session.
my @master_script =
  ( DL, # line      -> line
    'rot13 1 kyriel',
    DS, # line      -> stream
    'rot13 2 addi',
    DS, # stream    -> stream
    'rot13 3 attyz',
    DL, # stream    -> line
    'rot13 4 crimson',
    DR, # line      -> reference
    'rot13 5 crysflame',
    DR, # reference -> reference
    'rot13 6 dngor',
    DL, # reference -> line
    'rot13 7 freeside',
    DB, # line      -> block
    'rot13 8 halfjack',
    DB, # block     -> block
    'rot13 9 lenzo',
    DS, # block     -> stream
    'rot13 10 mendel',
    DR, # stream    -> reference
    'rot13 11 purl',
    DB, # reference -> block
    'rot13 12 roderick',
    DR, # block     -> reference
    'rot13 13 shizukesa',
    DS, # reference -> stream
    'rot13 14 simon',
    DB, # stream    -> block
    'rot13 15 sky',
    DL, # o/` and that brings us back to line o/`
    'rot13 16 stimps',

    'done',
  );

### Helpers to wrap payloads in mode-specific envelopes.  Stream and
### line modes don't need envelopes.

sub wrap_payload {
  my ($mode, $payload) = @_;

  # Pad/truncate blocks.
  if ($mode eq BLOCK) {
    $payload = pack 'A' . BLOCK_SIZE, $payload;
  }
  # Change the payload into a reference.
  elsif ($mode eq REFERENCE) {
    my $copy = $payload;
    $payload = \$copy;
  }

  return $payload;
}

sub unwrap_payload {
  my ($mode, $payload) = @_;

  # Unpad/truncate blocks.
  if ($mode eq BLOCK) {
    $payload = unpack 'A' . BLOCK_SIZE, $payload;
  }
  # Dereference referenced payloads.
  elsif ($mode eq REFERENCE) {
    $payload = $$payload;
  }

  return $payload;
}

### Slave session.  This session is controlled by the master session.
### It's also the server, in the client/server context.

sub slave_start {
  my $heap = $_[HEAP];

  $heap->{wheel} = POE::Wheel::ReadWrite->new
    ( InputHandle  => $slave_read,
      OutputHandle => $slave_write,
      Filter       => POE::Filter::Line->new(),
      Driver       => POE::Driver::SysRW->new(),
      InputState   => 'got_input',
      FlushedState => 'got_flush',
      ErrorState   => 'got_error',
    );

  $heap->{current_mode} = LINE;
  $heap->{shutting_down} = 0;

  DEBUG and warn "S: started\n";
}

sub slave_stop {
  DEBUG and warn "S: stopped\n";
}

sub slave_input {
  my ($heap, $input) = @_[HEAP, ARG0];
  my $mode = $heap->{current_mode};
  $input = &unwrap_payload( $mode, $input );
  DEBUG and warn "S: got $mode input: $input\n";

  # Asking us to switch modes.  Whee!
  if ($input =~ /^do (.+)$/) {
    my $response = "will $1";
    if ($1 eq LINE) {
      $heap->{wheel}->put( &wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter( POE::Filter::Line->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq STREAM) {
      $heap->{wheel}->put( &wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter( POE::Filter::Stream->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq REFERENCE) {
      $heap->{wheel}->put( &wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter( POE::Filter::Reference->new
                                  ( 'MyOtherFreezer'
                                  )
                                );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq BLOCK) {
      $heap->{wheel}->put( &wrap_payload( $mode, $response ) );
      $heap->{wheel}->set_filter( POE::Filter::Block->new() );
      $heap->{current_mode} = $1;
    }
    # Don't know; don't care; why bother?
    else {
      $heap->{wheel}->put( &wrap_payload( $mode, "wont $response" ) );
    }
    DEBUG and warn "S: switched to $1 filter\n";
    return;
  }

  # Asking us to respond in the current mode.  Whee!
  if ($input =~ /^rot13\s+(\d+)\s+(.+)$/) {
    my ($test_number, $query, $response) = ($1, $2, $2);
    $response =~ tr[a-zA-Z][n-za-mN-ZA-M];
    $heap->{wheel}->put( &wrap_payload( $mode,
                                        "rot13 $test_number $query=$response"
                                      ) );
    return;
  }

  # Telling us we're done.
  if ($input eq 'done') {
    DEBUG and warn "S: shutting down upon request\n";
    $heap->{wheel}->put( &wrap_payload( $mode, 'done' ) );
    $heap->{shutting_down} = 1;
    return;
  }

  if ($input eq 'oops') {
    DEBUG and warn "S: got oops... shutting down\n";
    delete $heap->{wheel};
  }
  else {
    $heap->{wheel}->put( &wrap_payload( $mode, 'oops' ) );
    $heap->{shutting_down} = 1;
  }
}

sub slave_flush {
  my $heap = $_[HEAP];
  if ($heap->{shutting_down}) {
    DEBUG and warn "S: shut down...\n";
    delete $heap->{wheel};
  }
}

sub slave_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
  DEBUG and do {
    warn "S: got $operation error $errnum: $errstr\n";
    warn "S: shutting down...\n";
  };
  delete $heap->{wheel};
}

### Master session.  This session controls the tests.  It's also the
### client, if you look at things from a client/server perspective.

sub master_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{wheel}   = POE::Wheel::ReadWrite->new
    ( InputHandle  => $master_read,
      OutputHandle => $master_write,
      Filter       => POE::Filter::Line->new(),
      Driver       => POE::Driver::SysRW->new(),
      InputState   => 'got_input',
      FlushedState => 'got_flush',
      ErrorState   => 'got_error',
    );

  $heap->{current_mode}  = LINE;
  $heap->{script_step}   = 0;
  $heap->{shutting_down} = 0;
  $kernel->yield( 'do_cmd' );

  DEBUG and warn "M: started\n";
}

sub master_stop {
  DEBUG and warn "M: stopped\n";
}

sub master_input {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];
  
  my $mode = $heap->{current_mode};
  $input = &unwrap_payload( $mode, $input );
  DEBUG and warn "M: got $mode input: $input\n";

  # Telling us they've switched modes.  Whee!
  if ($input =~ /^will (.+)$/) {
    if ($1 eq LINE) {
      $heap->{wheel}->set_filter( POE::Filter::Line->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq STREAM) {
      $heap->{wheel}->set_filter( POE::Filter::Stream->new() );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq REFERENCE) {
      $heap->{wheel}->set_filter( POE::Filter::Reference->new
                                  ( 'MyOtherFreezer'
                                  )
                                );
      $heap->{current_mode} = $1;
    }
    elsif ($1 eq BLOCK) {
      $heap->{wheel}->set_filter( POE::Filter::Block->new() );
      $heap->{current_mode} = $1;
    }
    # Don't know; don't care; why bother?
    else {
      die "dunno what $input means in real filter switching context";
    }

    DEBUG and warn "M: switched to $1 filter\n";
    $kernel->yield( 'do_cmd' );
    return;
  }

  # Telling us a response in the current mode.
  if ($input =~ /^rot13\s+(\d+)\s+(.*?)=(.*?)$/) {
    my ($test_number, $query, $response) = ($1, $2, $3);
    $query =~ tr[a-zA-Z][n-za-mN-ZA-M];
    if ($query eq $response) {
      &ok($test_number);
      DEBUG and warn "M: got ok rot13 response\n";
    }
    else {
      &not_ok($test_number);
      DEBUG and warn "M: got bad rot13 response\n";
    }

    $kernel->yield( 'do_cmd' );
    return;
  }

  if ($input eq 'done') {
    DEBUG and warn "M: got done ACK; shutting down\n";
    delete $heap->{wheel};
    return;
  }

  if ($input eq 'oops') {
    DEBUG and warn "M: got oops... shutting down\n";
    delete $heap->{wheel};
  }
  else {
    $heap->{wheel}->put( &wrap_payload( $mode, 'oops' ) );
    $heap->{shutting_down} = 1;
  }
}

sub master_do_next_command {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  my $script_step = $heap->{script_step}++;
  if ($script_step < @master_script) {
    DEBUG and
      warn "M: is sending cmd $script_step: $master_script[$script_step]\n";
    $heap->{wheel}->put( &wrap_payload( $heap->{current_mode},
                                        $master_script[$script_step],
                                      )
                       );
  }
  else {
    DEBUG and warn "M: is done sending commands...\n";
  }
}

sub master_flush {
  my $heap = $_[HEAP];
  if ($heap->{shutting_down}) {
    DEBUG and warn "S: shut down...\n";
    delete $heap->{wheel};
  }
}

sub master_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0..ARG2];
  DEBUG and do {
    warn "M: got $operation error $errnum: $errstr\n";
    warn "M: shutting down...\n";
  };
  delete $heap->{wheel};
}

### Main loop.

# Start the slave/server session first.
POE::Session->create
  ( inline_states =>
    { _start    => \&slave_start,
      _stop     => \&slave_stop,
      got_input => \&slave_input,
      got_flush => \&slave_flush,
      got_error => \&slave_error,
    }
  );

# Start the master/client session last.
POE::Session->create
  ( inline_states =>
    { _start    => \&master_start,
      _stop     => \&master_stop,
      got_input => \&master_input,
      got_flush => \&master_flush,
      got_error => \&master_error,
      do_cmd    => \&master_do_next_command,
    }
  );

# Begin a client and a server session on either side of a socket.  I
# think this is an improvement over forking.

$poe_kernel->run();

&ok(17);

### PARTIAL BUFFER TESTS.  (1) Create each test filter; (2) stuff each
### filter with a whole message and a part of one; (3) check that one
### whole message comes out; (4) check that get_pending returns the
### incomplete message; (5) check that get_pending again returns
### undef.

# Line filter.
{ my $filter = POE::Filter::Line->new();
  my $return = $filter->get( [ "whole line\x0D\x0A", "partial line" ] );
  if (defined $return) {
    &ok(18);
    &ok_if(19, @$return == 1);
    &ok_if(20, $return->[0] eq 'whole line');
    my $pending = $filter->get_pending();
    if (defined $pending) {
      &ok(21);
      &ok_if(22, @$pending == 1);
      &ok_if(23, $pending->[0] eq 'partial line');
    }
    else {
      &many_not_ok(21, 23);
    }
  }
  else {
    &many_not_ok(18, 23);
  }
}

# Block filter.
{ my $filter = POE::Filter::Block->new( BlockSize => 64 );
  my $return = $filter->get( [ pack('A64', "whole block"), "partial block" ] );
  if (defined $return) {
    &ok(24);
    &ok_if(25, @$return == 1);
    &ok_if(26, $return->[0] eq pack('A64', 'whole block'));
    my $pending = $filter->get_pending();
    if (defined $pending) {
      &ok(27);
      &ok_if(28, @$pending == 1);
      &ok_if(29, $pending->[0] eq 'partial block');
    }
    else {
      &many_not_ok(27, 29);
    }
  }
  else {
    &many_not_ok(24, 29);
  }
}

# Reference filter.
{ my $filter = POE::Filter::Line->new();
  my $return = $filter->get( [ "whole line\x0D\x0A", "partial line" ] );
  if (defined $return) {
    &ok(30);
    &ok_if(31, @$return == 1);
    &ok_if(32, $return->[0] eq 'whole line');
    my $pending = $filter->get_pending();
    if (defined $pending) {
      &ok(33);
      &ok_if(34, @$pending == 1);
      &ok_if(35, $pending->[0] eq 'partial line');
    }
    else {
      &many_not_ok(33, 35);
    }
  }
  else {
    &many_not_ok(30, 35);
  }
}

&ok(36);

&results;

exit;