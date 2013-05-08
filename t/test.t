#!/usr/bin/perl

use Test::More tests => 9;

use strict;
use warnings;

use Data::Dumper;
use MongoDB;
use DateTime;
use DateTime::Duration;
use MongoDB::Simple qw/ oid /;
use MTest;
use boolean;

my $client = MongoDB::MongoClient->new;
my $db = $client->get_database('mtest');
$db->drop if $db;

sub makeNewObject {
    my $obj = new MTest(client => $client);

    my $dt = shift || DateTime->now;
    my $meta = new MTest::Meta;
    $meta->type('meta type');
    my $label = new MTest::Label;
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

subtest 'MongoDB methods' => sub {
    plan tests => 2;

    my ($id, $dt, $meta, $label) = makeNewObject;

    my $obj = $db->get_collection('items')->find_one({'_id' => $id})->as('MTest');
#    my $obj = $db->get_collection('items')->find_one({'_id' => $id});
    isa_ok($obj, 'MTest', 'Object returned by find_one');

    my $cursor = $db->get_collection('items')->find;
    my $obj2 = $cursor->next->as('MTest');
    isa_ok($obj2, 'MTest', 'Object returned by cursor');
};

subtest 'Object methods' => sub {
    plan tests => 8;

    my $obj = new_ok('MTest');
    isa_ok($obj, 'MongoDB::Simple');

    # Has methods from MongoDB::Simple
    can_ok($obj, "client", "db", "col", "meta", "doc", "changes", "parent", "objcache", "arraycache", "existsInDb", "hasChanges");

    # Has mongodb related methods
    can_ok($obj, "getUpdates", "dump", "locator", "load", "save");

    # Has static methods
    can_ok($obj, "addmeta", "addfieldmeta", "getmeta", "package_start", "oid", "import", "new");

    # Has accessor methods
    can_ok($obj, "defaultAccessor", "stringAccessor", "booleanAccessor", "dateAccessor", "arrayAccessor", "objectAccessor", "dbrefAccessor");

    # Has helper keywords from MongoDB::Simple
    can_ok($obj, "database", "collection", "parent", "string", "date", "dbref", "boolean", "array", "object");

    # Has methods declared with keywords
    can_ok($obj, "name", "created", "available", "tags", "metadata", "labels");
};

subtest 'Accessors' => sub {
    plan tests => 14;

    my $obj = new MTest;

    is($obj->name, undef, 'String is undef');
    $obj->name('Test name');
    is($obj->name, 'Test name', 'String has been changed');

    is($obj->created, undef, 'Date is undef');
    my $dt = DateTime->now;
    $obj->created($dt);
    is($obj->created, $dt, 'Date has been changed');

    is($obj->available, undef, 'Boolean is undef');
    $obj->available(true);
    is($obj->available, true, 'Boolean has been changed');

    like(ref($obj->tags), qr/ARRAY/, 'Array is array reference');
    is(scalar @{$obj->tags}, 0, 'Array length is zero');

    is($obj->metadata, undef, 'Object is undef');
    my $meta = new MTest::Meta;
    $obj->metadata($meta);
    is($obj->metadata, $meta, 'Object has been changed');

    like(ref($obj->labels), qr/ARRAY/, 'Array is array reference');
    is(scalar @{$obj->labels}, 0, 'Array length is zero');
    my $label = new MTest::Label;
    push $obj->labels, $label;
    is(scalar @{$obj->labels}, 1, 'Array length is 1');
    is($obj->labels->[0], $label, 'Array contains object');
};

subtest 'Insert a document' => sub {
    plan tests => 2;

    my ($id, $dt, $meta, $label) = makeNewObject;

    is(ref($id), 'MongoDB::OID', 'Save returned MongoDB::OID');

    my $doc = $client->get_database('mtest')->get_collection('items')->find_one({'_id' => $id});
    is_deeply($doc, {
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
};

subtest 'Fetch a document' => sub {
    plan tests => 14;

    my ($id, $dt, $meta, $label) = makeNewObject;

    my $obj = new MTest(client => $client);
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');

    is_deeply($obj->doc, {
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

    is($obj->name, 'Test name', 'Name retrieved');
    is($obj->created, $dt, 'Date retrieved');
    is($obj->available, true, 'Boolean retrieved');
    is_deeply($obj->tags, ['tag1','tag2'], 'Array retrieved');
    is($obj->tags->[0], 'tag1', 'Array item[0] retrieved');
    is($obj->tags->[1], 'tag2', 'Array item[1] retrieved');
    is_deeply($obj->metadata->doc, $meta->doc, 'Object retrieved');
    is($obj->metadata->type, 'meta type', 'Object property retrieved');
    is(ref $obj->metadata, 'MTest::Meta', 'Typed object retrieved');
    is(ref $obj->labels->[0], 'MTest::Label', 'Typed array item[0] retrieved');
    is($obj->labels->[0]->text, 'test label', 'Typed array item[0] string retrieved');
    is_deeply($obj->attr, { key1 => 'key 1', key2 => 'key 2' }, 'Anonymous object retrieved');
};

subtest 'Update a document - scalars' => sub {
    plan tests => 14;

    my ($id, $dt, $meta, $label) = makeNewObject;

    my $obj = new MTest(client => $client);
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');

    is_deeply($obj->doc, {
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

    $obj->name('Updated name');
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is($obj->name, 'Updated name', 'String is updated');

    my $newdt = DateTime->now->add(DateTime::Duration->new( days => -1 ));
    $obj->created($newdt);
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is($obj->created, $newdt, 'Date is updated');

    $obj->available(false);
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is($obj->available, false, 'Boolean is updated');

    $obj->name(undef);
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is($obj->name, undef, 'String is undefined');

    $obj->created(undef);
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is($obj->created, undef, 'Date is undefined');

    $obj->available(undef);
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is($obj->available, undef, 'Boolean is undefined');
};

subtest 'Update a document - scalar arrays' => sub {
    plan tests => 6;

    my ($id, $dt, $meta, $label) = makeNewObject;

    my $obj = new MTest(client => $client);
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');

    is_deeply($obj->doc, {
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

    for(my $i = 0; $i < 5; $i++) { 
        push $obj->tags, 'new tag ' . ($i+1);;
    }
    is(scalar @{$obj->tags}, 7, 'New items are in array');
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is(scalar @{$obj->tags}, 7, 'New items can be retrieved');

    is_deeply($obj->doc, {
        "_id" => $id,
        "name" => 'Test name',
        "created" => DateTime::Format::W3CDTF->parse_datetime($dt) . 'Z',
        "available" => true,
        "attr" => { key1 => 'key 1', key2 => 'key 2' },
        "tags" => ['tag1', 'tag2', 'new tag 1', 'new tag 2', 'new tag 3', 'new tag 4', 'new tag 5'],
        "metadata" => {
            "type" => 'meta type'
        },
        "labels" => [
            { "text" => 'test label' }
        ]
    }, 'Correct document returned by MongoDB driver');
};

subtest 'Update a document - typed arrays' => sub {
    plan tests => 7;

    my ($id, $dt, $meta, $label) = makeNewObject;

    my $obj = new MTest(client => $client);
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');

    is_deeply($obj->doc, {
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

    my @labels = ();
    for(my $i = 0; $i < 5; $i++) { 
        my $l = new MTest::Label;
        $l->text('Label ' . ($i+1));
        push @labels, $l;
    }
    push $obj->labels, @labels;
    is(scalar @{$obj->labels}, 6, 'New items are in array');
    $obj->save;
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');
    is(scalar @{$obj->labels}, 6, 'New items can be retrieved');
    is(ref $obj->labels->[3], 'MTest::Label', 'Retrieved object has correct type');

    is_deeply($obj->doc, {
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
            { "text" => 'test label' },
            { "text" => 'Label 1' },
            { "text" => 'Label 2' },
            { "text" => 'Label 3' },
            { "text" => 'Label 4' },
            { "text" => 'Label 5' },
        ]
    }, 'Correct document returned by MongoDB driver');
};

subtest 'Update a document - objects' => sub {
    plan tests => 3;

    my ($id, $dt, $meta, $label) = makeNewObject;

    my $obj = new MTest(client => $client);
    $obj->load($id);
    is($obj->hasChanges, 0, 'Loaded document has no changes');

    is_deeply($obj->doc, {
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
   
    $obj->metadata->type('new meta type');
    $obj->save;
    $obj->load($id);
    is($obj->metadata->type, 'new meta type', 'String inside object is updated');
};
