package Chart::Clicker::SQL::REPL;
use Moose;
use 5.020;
use feature 'signatures', 'postderef';
no warnings 'experimental::signatures';
no warnings 'experimental::postderef';

use Browser::Open;
use File::HomeDir;
use File::Spec;
use File::Temp;
use List::Util;
use Module::Runtime;
use Path::Class;
use Scalar::Util;
use Term::ReadLine;
use Try::Tiny;

use Chart::Clicker::SQL;

has sql => (
    is        => 'rw',
    isa       => 'Chart::Clicker::SQL',
    predicate => 'initialized',
);

has history_file => (
    is      => 'ro',
    isa     => 'Str',
    default => sub {
        my $filename = File::Spec->catfile(
            File::HomeDir->my_data,
            '.ccsql_history'
        );
        file($filename)->touch;
        return $filename;
    },
);

has rl => (
    is      => 'ro',
    isa     => 'Term::ReadLine',
    lazy    => 1,
    default => sub ($self) {
        my $rl = Term::ReadLine->new(__PACKAGE__);
        for my $line (file($self->history_file)->slurp(chomp => 1)) {
            $rl->addhistory($line);
        }
        Scalar::Util::weaken(my $weakself = $self);
        $rl->Attribs->{completion_entry_function} = sub {
            ()
        };
        $rl->Attribs->{attempted_completion_function} = sub {
            $weakself->_attempt_completion(@_);
        };
        return $rl;
    },
);

has width => (
    is      => 'rw',
    isa     => 'Int',
    default => 1000,
);

has height => (
    is      => 'rw',
    isa     => 'Int',
    default => 600,
);

has last_query => (
    is        => 'rw',
    isa       => 'Str',
    predicate => 'has_last_query',
);

has domain_axis_class => (
    is      => 'rw',
    isa     => 'Str',
    default => 'Chart::Clicker::Axis',
);

has range_axis_class => (
    is      => 'rw',
    isa     => 'Str',
    default => 'Chart::Clicker::Axis',
);

has renderer_class => (
    is      => 'rw',
    isa     => 'Str',
    default => 'Chart::Clicker::Renderer::Line',
);

sub dsn ($self, $dsn) {
    $self->sql(Chart::Clicker::SQL->new(dsn => $dsn));
}

sub select ($self, $query) {
    $query = "select $query";
    $self->last_query($query);
}

sub timechart ($self, $args) {
    $self->domain_axis_class(
        $args eq 'on'
            ? "Chart::Clicker::Axis::DateTime"
            : "Chart::Clicker::Axis"
    )
}

for my $renderer (qw(Line StackedLine Bar StackedBar Area StackedArea Point)) {
    __PACKAGE__->meta->add_method(lc($renderer) => sub ($self, $args) {
        $self->renderer_class("Chart::Clicker::Renderer::$renderer");
    })
}

sub _draw ($self) {
    if (!$self->initialized) {
        warn "not initialized";
        return;
    }
    if (!$self->has_last_query) {
        warn "no active query";
        return;
    }
    my $chart = $self->sql->render($self->last_query);
    $self->_configure_chart($chart);
    my ($fh, $filename) = File::Temp::tempfile(SUFFIX => '.png', UNLINK => 1);
    $chart->draw;
    $fh->write($chart->rendered_data);
    $fh->flush;
    Browser::Open::open_browser("file://$filename");
}

sub _configure_chart ($self, $chart) {
    $chart->get_context('default')->domain_axis($self->_domain_axis);
    $chart->get_context('default')->range_axis($self->_range_axis);
    $chart->width($self->width);
    $chart->height($self->height);
    $chart->set_renderer($self->_renderer);
}

sub _domain_axis ($self) {
    Module::Runtime::require_module($self->domain_axis_class);
    return $self->domain_axis_class->new(
        orientation        => 'horizontal',
        position           => 'bottom',
        tick_division_type => 'LinearRounded',
    );
}

sub _range_axis ($self) {
    Module::Runtime::require_module($self->range_axis_class);
    return $self->range_axis_class->new(
        orientation        => 'vertical',
        position           => 'left',
        tick_division_type => 'LinearRounded',
    )
}

sub _renderer ($self) {
    Module::Runtime::require_module($self->renderer_class);
    return $self->renderer_class->new;
}

sub _can_draw ($self) {
    $self->initialized && $self->has_last_query
}

sub _attempt_completion ($self, $text, $line, $start, $end) {
    my ($initial_word) = $line =~ /^(\S+)\s+/;
    my @matches = $self->_get_completions($text, $initial_word);
    return $self->rl->completion_matches($text, sub ($text, $index) {
        return $matches[$index];
    });
}

sub _get_completions ($self, $text, $initial_word) {
    if ($initial_word) {
        my $completion_method = "_complete_$initial_word";
        return unless $self->can($completion_method);
        return $self->$completion_method($text);
    }
    else {
        my @keywords = grep {
            !/^_/
        } grep {
            !Moose::Object->can($_)
        } $self->meta->get_all_method_names;

        return $self->_keyword_complete($text, \@keywords);
    }
}

sub _complete_select ($self, $text) {
    $self->_keyword_complete(
        $text,
        [
            $self->_sql_keywords,
            $self->_sql_functions,
            $self->_sql_tables,
            $self->_sql_columns,
        ]
    )
}

sub _complete_timechart ($self, $text) {
    $self->_keyword_complete($text, [ qw(on off) ])
}

for my $method (qw(width height)) {
    __PACKAGE__->meta->add_method("_complete_$method" => sub ($self, $text) {
        $self->_default_complete($text, $method)
    })
}

sub _default_complete ($self, $text, $method) {
    $self->_keyword_complete($text, [ $self->$method ])
}

sub _keyword_complete ($self, $text, $keywords) {
    my ($prefix) = $text =~ /.*\b(\w+)$/;
    $prefix ||= '';
    my $capital = $prefix eq uc($prefix);
    return map {
        $prefix . substr($capital ? $_ : lc, length($prefix))
    } grep {
        /^\Q$prefix/i
    } $keywords->@*;
}

sub _sql_keywords ($self) {
    # just using sqlite keywords for now, but would be nice to switch this on
    # the backend engine in use based on the dsn at some point

    # https://www.sqlite.org/lang_keywords.html
    qw(
        ABORT ACTION ADD AFTER ALL ALTER ANALYZE AND AS ASC ATTACH
        AUTOINCREMENT BEFORE BEGIN BETWEEN BY CASCADE CASE CAST CHECK COLLATE
        COLUMN COMMIT CONFLICT CONSTRAINT CREATE CROSS CURRENT_DATE
        CURRENT_TIME CURRENT_TIMESTAMP DATABASE DEFAULT DEFERRABLE DEFERRED
        DELETE DESC DETACH DISTINCT DROP EACH ELSE END ESCAPE EXCEPT EXCLUSIVE
        EXISTS EXPLAIN FAIL FOR FOREIGN FROM FULL GLOB GROUP HAVING IF IGNORE
        IMMEDIATE IN INDEX INDEXED INITIALLY INNER INSERT INSTEAD INTERSECT
        INTO IS ISNULL JOIN KEY LEFT LIKE LIMIT MATCH NATURAL NO NOT NOTNULL
        NULL OF OFFSET ON OR ORDER OUTER PLAN PRAGMA PRIMARY QUERY RAISE
        RECURSIVE REFERENCES REGEXP REINDEX RELEASE RENAME REPLACE RESTRICT
        RIGHT ROLLBACK ROW SAVEPOINT SELECT SET TABLE TEMP TEMPORARY THEN TO
        TRANSACTION TRIGGER UNION UNIQUE UPDATE USING VACUUM VALUES VIEW
        VIRTUAL WHEN WHERE WITH WITHOUT
    )
}

sub _sql_functions ($self) {
    # just using sqlite functions for now, but would be nice to switch this on
    # the backend engine in use based on the dsn at some point

    my @functions = (
        # https://www.sqlite.org/lang_corefunc.html
        qw(
            abs changes char coalesce glob ifnull instr hex last_insert_rowid
            length like likelihood likely load_extension lower ltrim max min
            nullif printf quote random randomblob replace round rtrim soundex
            sqlite_compileoption_get sqlite_compileoption_used sqlite_source_id
            sqlite_version substr total_changes trim typeof unlikely unicode
            upper zeroblob
        ),
        # https://www.sqlite.org/lang_datefunc.html
        qw(
            date time datetime julianday strftime
        ),
        # https://www.sqlite.org/lang_aggfunc.html
        qw(
            avg count group_concat max min sum total
        ),
        # https://www.sqlite.org/json1.html
        qw(
            json json_array json_array_length json_extract json_insert
            json_object json_remove json_replace json_set json_type json_valid
            json_quote json_group_array json_group_object json_each json_tree
        ),
    );

    map { "$_(" } @functions
}

sub _sql_tables ($self) {
    return unless $self->initialized;
    my @tables = $self->sql->dbh->tables;
    my @table_components = map { split /\./ } @tables;
    my @all_tables = (@tables, @table_components);
    return (
        @all_tables,
        map { s/"//gr } @all_tables,
    );
}

sub _sql_columns ($self) {
    return unless $self->initialized;
    my $sth = $self->sql->dbh->column_info(undef, undef, undef, undef);
    my $rows = $sth->fetchall_arrayref;
    return List::Util::uniq map { $_->[3] } $rows->@*;
}

sub run ($self) {
    while (1) {
        my $prompt = "> ";
        if ($self->initialized) {
            $prompt = $self->sql->dsn . $prompt;
        }
        if (defined(my $input = $self->rl->readline($prompt))) {
            next unless length($input);
            chomp($input);
            last if $input eq 'exit';
            my ($command, $args) = split(' ', $input, 2);
            try {
                $self->$command($args);
                $self->_draw if $self->_can_draw
            }
            catch {
                warn $_;
            };
        }
        else {
            print "\n";
            last;
        }
    }
}

sub DEMOLISH ($self, $igd) {
    $self->rl->WriteHistory($self->history_file);
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
