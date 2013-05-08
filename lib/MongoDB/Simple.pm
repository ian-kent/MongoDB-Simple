package MongoDB::Simple;

#use MongoDB;
use Mojo::Base -base;
use Mojo::Exception;
use Exporter;
use Switch;
use DateTime;
use DateTime::Format::W3CDTF;
use MongoDB::Simple::ArrayType;
use Data::Dumper;
our @EXPORT = qw/ collection string date array object parent dbref boolean oid database /;

# package DB::User;
# use Mojo::Base 'MongoDB::Simple';
# use MongoDB::Simple;
#
# database 'scrum';
# collection 'users';
#
# string 'username' => undef;
# string 'password' => undef;
# date 'created' => undef;
# array 'permissions' => {
#     type => 'User::Permission'
# }
# object 'profile' => {
#     type => 'User::Profile'
# }
#
# -----
# 
# my $db = new DB::User;
# $db->load(oid('1'));
# my $username = $db->username;
# $username = 'foo';
# $db->username($username);
# $db->save;

has 'client'; # stores the client (or can be passed in)
has 'db'; # stores the database (or can be passed in)
has 'col'; # stores the collection (or can be passed in)
has 'meta'; # stores the keyword metadata
has 'doc'; # stores the document
has 'changes'; # stores changes made since load/save
has 'parent'; # stores the parent object
has 'objcache'; # stores created objects
has 'arraycache'; # stores array objects
has 'existsInDb';
has 'debugMode';

our %metadata = (); # internal metadata cache used for all packages

################################################################################
# Object methods                                                               #
################################################################################

sub new {
    my ($class, %args) = @_;

    my $self = Mojo::Base::new(@_);

    $self->meta($self->getmeta);
    if(!$self->col) {
        if(!$self->db) {
            if($self->client) {
                $self->db($self->client->get_database($self->meta->{database}));
            }
        }
        if($self->client && $self->db) {
            $self->col($self->db->get_collection($self->meta->{collection}));
        }
    }
    if(!$self->doc) {
        $self->doc({});
    }
    $self->changes({});
    $self->objcache({});
    $self->arraycache({});
    $self->existsInDb(0);

    # Done once first time new is called so field names can replace keywords below
    no strict 'refs';
    if(!$self->meta->{compiled}) {
        for my $field (keys %{$self->meta->{fields}}) {
            my $type = $self->meta->{fields}->{$field}->{type};
            $self->log("   -- injecting method for field '$field' as type '$type'");
            switch ($type) {
                case "string" { *{$class.'::'.$field} = sub { return stringAccessor(shift, $field, @_); } }
                case "date" { *{$class.'::'.$field} = sub { return dateAccessor(shift, $field, @_); } }
                case "boolean" { *{$class.'::'.$field} = sub { return booleanAccessor(shift, $field, @_); } }
                case "array" { *{$class.'::'.$field} = sub { return arrayAccessor(shift, $field, @_); } }
                case "object" { *{$class.'::'.$field} = sub { return objectAccessor(shift, $field, @_); } }
                case "dbref" { *{$class.'::'.$field} = sub { return dbrefAccessor(shift, $field, @_); } }
            }
            $self->log("-- creating field $field");
        }
        #addmeta('compiled', 1);
        my $pkg = ref $self;
        $metadata{$pkg}{compiled} = 1;
    }

    return $self;
}

sub log {
    my $self = shift;
    print STDERR (@_, "\n") if $self->debugMode;
}

sub load {
    #my ($self, $id) = @_;
    my $self = shift;

    my $doc = $self->col->find_one($self->locator(@_));

    if(!$doc) {
        Mojo::Exception->throw("Failed to load document with id: @_");
    }

    $self->existsInDb(1);
    $self->doc($doc);
    $self->changes({});
    $self->objcache({});
    $self->arraycache({});
}

# Can be overridden ($self, @args) to provide a different matching mechanism
sub locator {
    my ($self, $id) = @_;

    if(ref($id) !~ /HASH/) {
        return {
            "_id" => $id // $self->doc->{_id}
        };
    };
    return $id;
}

sub save {
    my ($self) = @_;

    if($self->existsInDb) {
        $self->log("Save:: updates:");
        my $updates = $self->getUpdates;
        $self->log(Dumper $updates);
        if(scalar keys %$updates == 0) {
            $self->log("No updates found, not saving");
            return 0;
        }
        $self->log("Exists in db, locator: " . $self->locator);
        $self->col->update($self->locator, $self->getUpdates);
    } else {
        my $changes = $self->changes;
        $self->log("nSave:: changes:");
        $self->log(Dumper $changes);
        $self->log("Doesn't exist in db");
        my $id = $self->col->insert($changes);
        $self->existsInDb(1);
        $self->log(Dumper $id);
        return $id;
    }
}

sub hasChanges {
    my ($self) = @_;

    return scalar keys %{$self->changes} > 0 ? 1 : 0;
}

sub getUpdates {
    my ($self) = @_;

    $self->log("getUpdates for " . ref($self));
    my %changes = ();

    for my $key (keys %{$self->changes}) {
        next if $self->meta->{fields}->{$key}->{type} =~ /array/i;
        $self->log(" - adding change for $key:");
        $self->log(Dumper $self->changes->{$key});
        $changes{'$set'}{$key} = $self->changes->{$key};
    }

    for my $field (keys %{$self->meta->{fields}}) {
        $self->log("checking field $field");
        if($self->meta->{fields}->{$field}->{type} =~ /object/i) {
            $self->log(" - field $field is object type");
            my $obj = $self->$field;
            my $chng = ref($obj) && ref($obj) !~ /HASH/ ? $obj->getUpdates : $obj;
            $self->log(Dumper $chng);
            for my $chg (keys %{$chng->{'$set'}}) {
                $changes{'$set'}{"$field.$chg"} = $chng->{'$set'}->{$chg};
            }
        }
        if($self->meta->{fields}->{$field}->{type} =~ /array/i) {
            $self->log(" - field $field is array type");
            $self->$field; # triggers array initialisation if it hasn't already happened
            my $arr = $self->arraycache->{$field}->{objref};
            my $chng = $arr->changes;
            $self->log(Dumper $chng);
            my %types = ( '$push' => '$pushAll' );
            for my $type (keys %types) {
                my $mtype = $types{$type}; 
                for my $chg (@{$chng->{$type}}) {
                    $changes{$mtype}{$field} = [] if !$changes{$mtype}{"$field"};
                    push @{$changes{$mtype}{"$field"}}, $chg->doc;
                }
            }
        }
    }

    $self->log(Dumper \%changes);
    return \%changes;
}

sub dump {
    my ($self) = @_;

    $self->log("Dumping " . (ref $self));
    for my $field ( keys %{$self->meta->{fields}} ) {
        $self->log("    $field => " . $self->$field);
    }
}

################################################################################
# Accessor methods                                                             #
################################################################################

sub defaultAccessor {
    my ($self, $field, $value) = @_;

    if(scalar @_ <= 2) {
        return $self->changes->{$field} // $self->doc->{$field};
    }

    return if $self->doc && $value && $self->doc->{$field} && $value eq $self->doc->{$field};

    $self->changes->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->doc->{$field} = $value;
}

sub stringAccessor {
    return defaultAccessor(@_);
}
sub booleanAccessor {
    return defaultAccessor(@_);
}
sub dateAccessor {
    my ($self, $field, $value) = @_;

    if(scalar @_ <= 2) {
        $value = $self->changes->{$field} // $self->doc->{$field};
        $value = DateTime::Format::W3CDTF->new->parse_datetime($value) if $value;
        return $value;
    }

    if(ref($value) =~ /DateTime/) {
        $value = DateTime::Format::W3CDTF->new->format_datetime($value);
    }

    return if $self->doc && $value && $self->doc->{$field} && $value eq $self->doc->{$field};

    $self->changes->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->doc->{$field} = $value;
}
sub arrayAccessor {
    my ($self, $field, $value) = @_;

    if(scalar @_ <= 2) {
        if($self->arraycache->{$field}) {
            return $self->arraycache->{$field}->{arrayref};
        }

        my @arr;
        my $docval = $self->doc->{$field};
        if($docval) {
            for my $item (@$docval) {
                my $type = $self->meta->{fields}->{$field}->{args}->{type};
                if($type) {
                    push @arr, $type->new(parent => $self, doc => $item);
                } else {
                    push @arr, $item;
                }
            }
        }
        my $a = tie my @array, 'MongoDB::Simple::ArrayType', parent => $self, field => $field, array => \@arr;
        $self->arraycache->{$field} = {
            arrayref => \@array,
            objref => $a
        };

        return \@array;
    }

    return if $self->doc && $value && $self->doc->{$field} && $value eq $self->doc->{$field};

    if(!tied($value)) {
        my @array;
        my $a = tie @array, 'MongoDB::Simple::ArrayType', parent => $self, field => $field;
        $self->arraycache->{$field} = {
            arrayref => \@array,
            objref => $a
        };
        push @array, @$value;
        $value = $a->array;
    }

    $self->changes->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->doc->{$field} = $value;
}
sub objectAccessor {
    my ($self, $field, $value) = @_;

    my $type = $self->meta->{fields}->{$field}->{args}->{type};
    my $obj;

    if(scalar @_ <= 2) {
        if($type) {
            if($self->objcache->{$field}) {
                return $self->objcache->{$field};
            }
            if($self->doc->{$field}) {
                $obj = $type->new(parent => $self, doc => $self->doc->{$field});
                $self->objcache->{$field} = $obj;
            }
            return $obj;
        }
        return $self->doc->{$field};
    }

    if(ref($value) !~ /^HASH$/) {
        $self->objcache->{$field} = $value;
        $value->parent($self);
        $value = $value->doc;
    }
    return if $self->doc && $value && $self->doc->{$field} && $value eq $self->doc->{$field};

    $self->changes->{$field} = $value;
    # XXX unsure if we want to set doc or not.... if we do, it makes insert/upsert easier
    $self->doc->{$field} = $value;

    return;
} 
sub dbrefAccessor {
    return defaultAccessor(@_);
}

################################################################################
# Static methods                                                               #
################################################################################

sub import {
    $Exporter::ExportLevel = 1;
    Exporter::import(@_);
}

sub addmeta {
    my ($key, $meta) = @_;
    my $pack = caller 1;
    $metadata{$pack}{$key} = $meta;
    #print "addmeta: adding '$key' to $pack\n";
}
sub addfieldmeta {
    my ($field, $meta) = @_;
    my $pack = caller 1;
    $metadata{$pack}{'fields'}{$field} = $meta;
    #print "addfield: adding '$field' to $pack fields\n";
}

sub getmeta {
    my ($self) = @_;
    my $pack = ref $self;
    #print "getmeta: $pack\n";
    return \%{$metadata{$pack}};
}

sub package_start {
    my $class = caller 1;
    #print "-" x 80;
    #print "\n";
    #print "MongoDB:: Package '$class'\n";
}

sub oid {
    my ($id) = @_;
    return new MongoDB::OID(value => $id);
}

################################################################################
# Keywords                                                                     #
################################################################################

sub database {
    my ($database) = @_;
    addmeta("database", $database);
    #print STDERR "MongoDB:: database '$database'\n";
}

sub collection {
    my ($collection) = @_;
    package_start;
    addmeta("collection", $collection);
    #print STDERR "MongoDB:: collection '$collection'\n";
}

sub parent {
    my (%hash) = @_;
    package_start;
    addmeta("parent", \%hash);
    #print STDERR "MongoDB:: parent { type => '$hash{type}', key => '$hash{key}' }\n";
}

sub string {
    my ($key, $value) = @_;
    $value = '<undef>' if !defined $value;
    addfieldmeta($key, { type => 'string', value => $value });
    #print STDERR "MongoDB:: string '$key' => $value\n";
}

sub date {
    my ($key, $value) = @_;
    $value = '<undef>' if !defined $value;
    addfieldmeta($key, { type => 'date', value => $value });
    #print STDERR "MongoDB:: date '$key' => $value\n";
}

sub dbref {
    my ($key, $args) = @_;
    #print STDERR "MongoDB:: dbref '$key' =>\n";
    addfieldmeta($key, { type => 'dbref', args => $args });
    for my $ref ( keys %$args ) {
        #print STDERR "    - '$ref' => $args->{$ref}\n";
    }
}

sub boolean {
    my ($key, $value) = @_;
    $value = '<undef>' if !defined $value;
    addfieldmeta($key, { type => 'boolean', value => $value });
    #print STDERR "MongoDB:: boolean '$key' => $value\n";
}

sub array {
    my ($key, $args) = @_;
    addfieldmeta($key, { type => 'array', args => $args });
    #print STDERR "MongoDB:: array '$key' => { type => '$args->{type}' }\n";
}

sub object {
    my ($key, $args) = @_;
    addfieldmeta($key, { type => 'object', args => $args });
    #print STDERR "MongoDB:: object '$key' => { type => '$args->{type}' }\n";
}

1;
