package MongoDB::Simple::HashType;

use strict;
use warnings;
our $VERSION = '0.005';

use Tie::Hash;
our @ISA = ('Tie::Hash');

# Copied from Tie::StdArray and modified to use a hash

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        'hash' => {},
        'parent' => undef,
        'field' => undef,
        'meta' => undef,
        'doc' => {}, # represents the hashref used by mongodb
        %args
    }, $class;

    $self->{meta} = $self->{parent}->{meta}->{fields}->{$self->{field}};

    return $self;
}

sub TIEHASH  { 
    my $class = shift;
    return $class->new(@_);
}

sub STORE    { 
    my ($self, $key, $value) = @_;
    $self->{parent}->log("HashType::Store key[$key], value[$value]");
    $self->{hash}->{$key} = $value;
    # TODO deal with non-scalar values (tie hashes/arrays, set key for change tracking)
    $self->{parent}->registerChange($self->{field} . '.' . $key, '$set', $value);
}
sub FETCH    {
    my ($self, $key) = @_;
    # TODO add key to non-scalar values (for object/array/hash change tracking)
    $self->{parent}->log("HashType::Fetch key[$key]");
    return $self->{hash}->{$key};
}
sub FIRSTKEY { 
    my ($self) = @_;
    my $a = keys %{$self->{hash}};
    return each %{$self->{hash}};
}
sub NEXTKEY  { 
    my ($self) = @_;
    return each %{$self->{hash}};
}
sub EXISTS   { 
    my ($self, $key) = @_;
    return exists $self->{$key};
}
sub DELETE   {
    my ($self, $key) = @_;
    # TODO register change for delete
    delete $self->{$key}; 
}
sub CLEAR    { 
    my ($self) = @_;
    # TODO register change for clear
    %{$self->{hash}} = ();
}
sub SCALAR   { 
    my ($self) = @_;
    return scalar %{$self->{hash}};
}

1;
