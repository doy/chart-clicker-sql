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
use Module::Runtime;
use Path::Class;
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
