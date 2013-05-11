#!/usr/bin/perl

use Test::More tests => 1;
use Test::Warn;

use strict;
use warnings;

use Data::Dumper;
use MongoDB;
use DateTime;
use DateTime::Duration;
use MongoDB::Simple qw/ oid /;
use MongoDB::Simple::Test;
use boolean;

# Make sure we have mongodb installed, otherwise skip all tests
my $client;
my $db;
eval {
    my $host = "localhost";
    if (exists $ENV{MONGOD}) {
        $host = $ENV{MONGOD};
    }
    $client = MongoDB::MongoClient->new(host => $host, ssl => $ENV{MONGO_SSL});
    $db = $client->get_database('mtest');
    $db->drop if $db;
} if !$ENV{MONGODB_SIMPLE_TEST_NOCONNECTION};

# Helper method to create a new object
sub makeNewObject {
    my $obj = new MongoDB::Simple::Test(client => $client);

    my $dt = shift || DateTime->now;
    my $meta = new MongoDB::Simple::Test::Meta;
    $meta->type('meta type');
    my $label = new MongoDB::Simple::Test::Label;
    $label->text('test label');

    $obj->name('Test name');
    $obj->created($dt);
    $obj->available(true);
    $obj->attr({ key1 => 'key 1', key2 => 'key 2' });
    $obj->tags(['tag1', 'tag2']);
    $obj->metadata($meta);
    push $obj->labels, $label;

    my $id = $obj->save;
    return ($id, $dt, $meta, $label);
}

subtest 'Updating dupliacted data' => sub {
    plan tests => 4;

    SKIP: {
        skip 'MongoDB connection required for test', 4 if !$client;

        my ($id, $dt, $meta, $label) = makeNewObject;

        my $obj = new MongoDB::Simple::Test(client => $client);
        $obj->load($id);
        is($obj->hasChanges, 0, 'Loaded document has no changes');

        is_deeply($obj->{doc}, {
            "_id" => $id,
            "name" => 'Test name',
            "created" => DateTime::Format::W3CDTF->parse_datetime($dt) . 'Z',
            "available" => true,
            "attr" => { key1 => 'key 1', key2 => 'key 2' },
            "tags" => ['tag1', 'tag2'],
            "metadata" => {
                "type" => 'meta type'
            },
            "labels" => [
                {
                    "text" => 'test label'
                }
            ]
        }, 'Correct document returned by MongoDB driver');

        my $dup = new MongoDB::Simple::Test::Duplicate(client => $client);
        $dup->item_id({'$ref' => 'items', '$id' => $id});
        $dup->name('Test name');
        my $dup_id = $dup->save;

        isa_ok($dup_id, 'MongoDB::OID', 'Duplicate object returned id');

        $obj->name('New name');
        $obj->save;

        $dup->load($id);
        is($dup->name, 'New name', 'Name in duplicate data has changed');
    }
};
