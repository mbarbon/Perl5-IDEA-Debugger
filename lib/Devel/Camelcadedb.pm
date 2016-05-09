# http://perldoc.perl.org/DB.html
# http://perldoc.perl.org/perldebug.html
# http://perldoc.perl.org/perldebtut.html
# http://perldoc.perl.org/perldebguts.html
package DB;
use 5.008;
use strict;
use warnings;
use IO::Socket::INET;
use PadWalker qw/peek_my/;
use Scalar::Util;
#use constant {
#    FLAG_SUB_ENTER_EXIT         => 0x01,
#    FLAG_LINE_BY_LINE           => 0x02,
#    FLAG_OPTIMIZATIONS_OFF      => 0x04,
#    FLAG_MORE_DATA              => 0x08,
#    FLAG_SOURCE_LINES           => 0x10,
#    FLAG_SINGLE_STEP_ON         => 0x20,
#    FLAG_USE_SUB_ADDRESS        => 0x40,
#    FLAG_REPORT_GOTO            => 0x80,
#    FLAG_EVAL_FILENAMES         => 0x100,
#    FLAG_ANON_FILENAMES         => 0x200,
#    FLAG_STORE_SOURCES          => 0x400,
#    FLAG_KEEP_SUBLESS_EVALS     => 0x800,
#    FLAG_KEEP_UNCOMPILED_SOURCE => 0x1000,
#    FLAGS_DESCRIPTIVE_NAMES     => [
#        q{Debug subroutine enter/exit.},
#        q{Line-by-line debugging. Causes DB::DB() subroutine to be called for each statement executed. Also causes saving source code lines (like 0x400).}
#        ,
#        q{Switch off optimizations.},
#        q{Preserve more data for future interactive inspections.},
#        q{Keep info about source lines on which a subroutine is defined.},
#        q{Start with single-step on.},
#        q{Use subroutine address instead of name when reporting.},
#        q{Report goto &subroutine as well.},
#        q{Provide informative "file" names for evals based on the place they were compiled.},
#        q{Provide informative names to anonymous subroutines based on the place they were compiled.},
#        q{Save source code lines into @{"::_<$filename"}.},
#        q{When saving source, include evals that generate no subroutines.},
#        q{When saving source, include source that did not compile.},
#    ],
#};

sub FLAG_REPORT_GOTO() {0x80;}

sub STEP_CONTINUE() {0;}
sub STEP_INTO() {1;}
sub STEP_OVER() {2;}

# Each array @{"::_<$filename"} holds the lines of $filename for a file compiled by Perl. The same is also true for evaled
# strings that contain subroutines, or which are currently being executed. The $filename for evaled strings looks like
# (eval 34) .
# Values in this array are magical in numeric context: they compare equal to zero only if the line is not breakable.
#
# # @DB::dbline is an alias for @{"::_<current_file"} , which holds the lines of the currently-selected file (compiled by
# Perl), either explicitly chosen with the debugger's f command, or implicitly by flow of execution.
#
our @dbline = ();     # list of lines in currently loaded file

# Each hash %{"::_<$filename"} contains breakpoints and actions keyed by line number. Individual entries (as opposed to
# the whole hash) are settable. Perl only cares about Boolean true here, although the values used by perl5db.pl have the
# form "$break_condition\0$action" .
#
# The same holds for evaluated strings that contain subroutines, or which are currently being executed. The $filename
# for evaled strings looks like (eval 34) .
#
# %DB::dbline is an alias for %{"::_<current_file"} , which contains breakpoints and actions keyed by line number in
# the currently-selected file, either explicitly chosen with the debugger's f command, or implicitly by flow of execution.
# As previously noted, individual entries (as opposed to the whole hash) are settable. Perl only cares about Boolean
# true here, although the values used by perl5db.pl have the form "$break_condition\0$action" .
#
# Actions in current file (keys are line numbers). The values are strings that have the sprintf(3) format
# ("%s\000%s", breakcondition, actioncode) .
our %dbline = ();     # actions in current file (keyed by line number)

# Each scalar ${"::_<$filename"} contains "::_<$filename" . This is also the case for evaluated strings that contain
# subroutines, or which are currently being executed. The $filename for evaled strings looks like (eval 34) .
#
our $dbline;

# DB::dump_trace(skip[,count]) skips the specified number of frames and returns a list containing information about the
# calling frames (all of them, if count is missing). Each entry is reference to a hash with keys context (either ., $ ,
# or @ ), sub (subroutine name, or info about eval), args (undef or a reference to an array), file , and line .
#

# these are hardcoded in perl source (some are magical)

# When execution of the program reaches a subroutine call, a call to &DB::sub (args) is made instead, with $DB::sub
# holding the name of the called subroutine. (This doesn't happen if the subroutine was compiled in the DB package.)
our $sub = '';        # Name of current executing subroutine.

# A hash %DB::sub is maintained, whose keys are subroutine names and whose values have the form
# filename:startline-endline . filename has the form (eval 34) for subroutines defined inside evals.
#
# The keys of this hash are the names of all the known subroutines. Each value is an encoded string that has the
# sprintf(3) format ("%s:%d-%d", filename, fromline, toline) .
our %sub = ();        # "filename:fromline-toline" for every known sub

# If you set $DB::single to 2, it's equivalent to having just typed the step over command, whereas a value of 1
# means the step into command.
our $single = 0;      # single-step flag (set it to 1 to enable stops in BEGIN/use) 1 -into, 2 - over

# Signal flag. Will be set to a true value if a signal was caught. Clients may check for this flag to abort
# time-consuming operations.
our $signal = 0;

# The $DB::trace variable should be set to 1 to simulate having typed the t command.
# This flag is set to true if the API is tracing through subroutine calls.
our $trace = 0;       # are we tracing through subroutine calls?

# For example, whenever you call Perl's built-in caller function from the package DB , the arguments that the
# corresponding stack frame was called with are copied to the @DB::args array. These mechanisms are enabled by calling
# Perl with the -d switch. Specifically, the following additional features are enabled (cf. $^P in perlvar):
our @args = ();       # arguments of current subroutine or @ARGV array

our @ret = ();        # return value of last sub executed in list context
our $ret = '';        # return value of last sub executed in scalar context

my %_perl_file_id_to_path_map = ();  # map of perl file ids without _<  => real path detected on loading
my %_paths_to_perl_file_id_map = (); # maps real paths to _<filename

my %_loaded_breakpoints = (); # map of loaded breakpoints, set and not in form: path => line => object
my %_references_cache = ();   # cache of soft references from peek_my

my @glob_slots = qw/SCALAR ARRAY HASH CODE IO FORMAT/;
my $glob_slots = join '|', @glob_slots;

my $_debug_server_host;     # remote debugger host
my $_debug_server_port;     # remote debugger port

my $_local_debug_host;      # local debug host
my $_local_debug_port;      # local debug port

my $_debug_net_role;        # server or client, we'll use ENV for this
my $_debug_socket;
my $_debug_packed_address;

my $coder;  # JSON::XS coder
my $deparser; # B::Deparse deparser

my $frame_prefix_step = "  ";
my $frame_prefix = '';

my $_internal_process = 0;

my @saved;  # saved runtime environment

my $current_package;
my $current_file_id;
my $current_line;

my $trace_set_db_line = 1; # report _set_dbline invocation
my $trace_code_stack_and_frames = 0; # report traces on entering code
my $trace_real_path = 0; # trasing real path transition

my $ready_to_go = 0; # set after debugger been initialized

my $_stack_frames = [ ];     # stack frames

sub _dump
{
    require Data::Dumper;
    return Data::Dumper->Dump( [ @_ ] );
}

sub _report($;@)
{
    my ($message, @sprintf_args) = @_;
    chomp $message;
    printf STDERR "$message\n", @sprintf_args;
}

sub _format_caller
{
    my (@caller) = @_;
    return sprintf "%s %s%s%s from %s::, %s line %s; %s %s %s %s",
        map $_ // 'undef',
                defined $caller[5] ? $caller[5] ? 'array' : 'scalar' : 'void', # wantarray
            $caller[3], # target sub
                $caller[4] ? '(@_)' : '', # has args
                $caller[7] ? ' [require '.$caller[6].']' : '', # is_require and evaltext
            $caller[0], # package
            $caller[1], # filename
            $caller[2], # line
                $caller[7] ? '' : $caller[6] // '', # evaltext if no isrequire
            $caller[8], # strcit
            $caller[9], # warnings
            $caller[10], # hinthash
    ;
}

sub _send_event
{
    my ($name, $data) = @_;

    _send_data_to_debugger( +{
            event => $name,
            data  => $data
        } );
}

sub _get_loaded_files_map
{
    my %result = ();
    foreach(keys %::)
    {
        next unless /^_</;
        next if /\(eval/;
        my $glob = $::{$_};
        next unless *$glob{ARRAY} && scalar @{*$glob{ARRAY}};
        $result{$_} = ${*$glob};
    }
    return \%result;
}

sub _dump_stack
{
    my $depth = 0;
    _report $frame_prefix."Stack trace:\n";
    while()
    {
        my @caller = caller( $depth );
        last unless defined $caller[2];
        printf STDERR $frame_prefix.$frame_prefix_step."%s: %s\n", $depth++, _format_caller( @caller );
    }
    1;
}

sub _dump_frames
{
    my $depth = 0;
    _report $frame_prefix."Frames trace:\n";
    foreach my $frame (@$_stack_frames)
    {
        printf STDERR $frame_prefix.$frame_prefix_step."%s: %s\n", $depth++,
            join ', ', map $_ // 'undef', @$frame{qw/subname file current_line _single/},
                        $frame->{is_use_block} ? '(use block)' : ''
        ;
    }
    1;
}

sub _deparse_code
{
    my ($code) = @_;
    $deparser ||= B::Deparse->new();
    return $deparser->coderef2text( $code );
}

sub _get_reference_subelements
{
    my ($request_serialized_object) = @_;
    my $request_object = _deserialize( $request_serialized_object );
    my ($offset, $size, $key) = @$request_object{qw/offset limit key/};
    my $data = [ ];

    my $source_data;

    if ($key =~ /^\*(.+?)(?:\{($glob_slots)\})?$/) # hack for globs
    {
        no strict 'refs';
        my ( $name, $slot) = ($1, $2);

        if ($slot)
        {
            $source_data = *{$name}{$slot};
        }
        else
        {
            $source_data = \*{$name};
        }

        print STDERR "Got glob ref $key => $source_data";
    }
    else
    {
        $source_data = $_references_cache{$key};
    }

    if ($source_data)
    {
        my $reftype = Scalar::Util::reftype( $source_data );

        if ($reftype eq 'ARRAY' && $#$source_data >= $offset)
        {
            my $last_index = $offset + $size;

            for (my $item_number = $offset; $item_number < $last_index && $item_number < @$source_data; $item_number++)
            {
                push @$data, _get_reference_descriptor( "[$item_number]", \$source_data->[$item_number] );
            }
        }
        elsif ($reftype eq 'HASH')
        {
            my @keys = sort keys %$source_data;
            if ($#keys >= $offset)
            {
                my $last_index = $offset + $size;

                for (my $item_number = $offset; $item_number < $last_index && $item_number < @keys; $item_number++)
                {
                    my $hash_key = $keys[$item_number];
                    push @$data, _get_reference_descriptor( "'$hash_key'", \$source_data->{$hash_key} );
                }
            }
        }
        elsif ($reftype eq 'REF')
        {
            push @$data, _get_reference_descriptor( $source_data, \$$source_data );
        }
        elsif ($reftype eq 'GLOB')
        {
            no strict 'refs';
            foreach my $glob_slot (@glob_slots)
            {
                my $reference = *$source_data{$glob_slot};
                next unless $reference;
                my $desciptor = _get_reference_descriptor( $glob_slot, \$reference );

                # hack for DB namespace, see https://github.com/hurricup/Perl5-IDEA/issues/1151
                if ($glob_slot eq 'HASH' && $key =~ /^\*(::)*(main::)*(::)*DB(::)?$/)
                {
                    $desciptor->{expandable} = \0;
                    $desciptor->{size} = 0;
                }

                $desciptor->{key} = $key."{$glob_slot}";
                push @$data, $desciptor;
            }
        }
        else
        {
            print STDERR "Dont know how to iterate $reftype";
        }

    }
    else
    {
        print STDERR "No source data for $key\n";
    }

    _send_data_to_debugger( $data );
}

sub _format_variables
{
    my ($vars_hash) = @_;
    my $result = [ ];

    foreach my $variable (sort keys %$vars_hash)
    {
        my $value = $vars_hash->{$variable};
        push @$result, _get_reference_descriptor( $variable, $value );
    }

    return $result;
}

sub _get_reference_descriptor
{
    my ($name, $value) = @_;

    my $key = $value;
    my $reftype = Scalar::Util::reftype( $value );
    my $ref = ref $value;

    my $size = 0;
    my $type = $ref;
    my $expandable = \0;
    my $is_blessed = $ref && Scalar::Util::blessed( $value ) ? \1 : \0;
    my $ref_depth = 0;

    if (!$reftype)
    {
        $type = "SCALAR";
    }
    elsif ($reftype eq 'SCALAR')
    {
        $value = defined $$value ? "'$$value'" : 'undef';
    }
    elsif ($reftype eq 'REF')
    {
        my $result = _get_reference_descriptor( $name, $$value );
        $result->{ref_depth}++;
        return $result;
    }
    elsif ($reftype eq 'ARRAY')
    {
        $size = scalar @$value;
        $value = sprintf "ARRAY[%s]", $size;
        $expandable = $size ? \1 : \0;
    }
    elsif ($reftype eq 'HASH')
    {
        $size = scalar keys %$value;
        $value = sprintf "HASH{%s}", $size;
        $expandable = $size ? \1 : \0;
    }
    elsif ($reftype eq 'GLOB')
    {
        no strict 'refs';
        $size = scalar grep *$value{$_}, @glob_slots;
        $key = $value = "*".*$value{PACKAGE}."::".*$value{NAME};
        $reftype = undef;
        $expandable = $size ? \1 : \0;
    }

    my $char_code;
    my $stringified_key = "$key";
    $stringified_key =~ s{(.)}{
        $char_code = ord( $1 );
        $char_code < 32 ? '^'.chr( $char_code + 0x40 ) : $1
        }gsex;

    if ($reftype)
    {
        $_references_cache{$stringified_key} = $key;
    }

    $name = "$name";
    $value = "$value";

    $name =~ s{(.)}{
        $char_code = ord( $1 );
        $char_code < 32 ? '^'.chr( $char_code + 0x40 ) : $1
        }gsex;
    $value =~ s{(.)}{
        $char_code = ord( $1 );
        $char_code < 32 ? '^'.chr( $char_code + 0x40 ) : $1
        }gsex;

    return +{
        name       => "$name",
        value      => "$value",
        type       => "$type",
        expandable => $expandable,
        key        => $stringified_key,
        size       => $size,
        blessed    => $is_blessed,
        ref_depth  => $ref_depth,
    };
}

sub _render_variables
{
    my ($vars_hash) = @_;
    my $result = '';

    require Scalar::Util;

    foreach my $variable (keys %$vars_hash)
    {
        my $value = $vars_hash->{$variable};

        my $reftype = Scalar::Util::reftype $value;
        my $ref = ref $value;
        my $appendix = '';

        if ($reftype eq 'SCALAR')
        {
            $value = $$value // '_UNDEF_';
        }
        elsif ($reftype eq 'ARRAY')
        {
            $appendix = sprintf '[%s]', scalar @$value;
            my @elements = @$value;
            if (@elements > 1000)
            {
                splice @elements, 3; # should be a 1000 here and method to get the rest
                push @elements, '...'
            }
            $value = sprintf "(%s)", join ',', map { $_ // '__UNDEF__'} @elements;
        }
        elsif ($reftype eq 'HASH')
        {
            my @elements = sort keys %$value; # sorting is necessary to iterate and get data frame
            $appendix = sprintf '{%s}', scalar @elements;

            if (@elements > 1000)
            {
                splice @elements, 3; # should be a 1000 here and method to get the rest
                push @elements, '...'
            }
            $value = sprintf "(\n%s\n)", join ",\n", map { "\t\t".$_." => ".$value->{$_}} @elements;
        }
        elsif (ref $value eq 'REF')
        {
            $value = $$value;
        }

        $result .= "\t$ref $variable$appendix = $value\n";
    }

    return $result;
}

sub _get_current_stack_frame
{
    return $_stack_frames->[0];
}

sub _send_data_to_debugger
{
    my ($event) = @_;
    _send_string_to_debugger( _serialize( $event ) );
}

sub _send_string_to_debugger
{
    my ($string) = @_;
    $string .= "\n";
    print $_debug_socket $string;
    print STDERR "* Sent to debugger: $string";
}

sub _get_adjusted_line_number
{
    my ($line_number) = @_;
    return $line_number - 1;
}

#@returns JSON::XS
sub _get_seraizlier
{
    unless ($coder)
    {
        $coder = JSON::XS->new();
        $coder->latin1();
    }
    return $coder;
}

sub _serialize
{
    my ($data) = @_;
    return _get_seraizlier->encode( $data );
}

sub _deserialize
{
    my ($json_string) = @_;
    return _get_seraizlier->decode( $json_string );
}

sub _calc_stack_frames
{
    my $frames = [ ];
    my $depth = 0;
    %_references_cache = ();

    while ()
    {
        my ($package, $filename, $line, $subroutine, $hasargs,
            $wantarray, $evaltext, $is_require, $hints, $bitmask, $hinthash) = caller( $depth );

        last unless defined $filename;

        if ($package && $package ne 'DB')
        {
            if (@$frames)
            {
                $frames->[-1]->{name} = $subroutine;
            }

            my $lexical_variables = [ ];
            my $variables_hash = eval {peek_my( $depth + 1 )};
            unless ($@)
            {
                $lexical_variables = _format_variables( $variables_hash );
            }

            push @$frames, {
                    file     => _get_real_path_by_normalized_perl_file_id( $filename ),
                    line     => $line - 1,
                    name     => 'main::',
                    lexicals => $lexical_variables
                };
        }

        $depth++;
    }

    return $frames;
}

sub _event_handler
{
    _send_event( "STOP", _calc_stack_frames() );

    while()
    {
        print STDERR "Waiting for input\n";
        my $command = <$_debug_socket>;
        die 'Debugging socket disconnected' if !defined $command;
        $command =~ s/[\r\n]+$//;
        print STDERR "============> Got command: '$command'\n";

        if ($command eq 'q')
        {
            print STDERR "Exiting";
            exit;
        }
        elsif ($command eq 'l') # list
        {
            for (my $i = 0; $i < @DB::dbline; $i++)
            {
                my $src = $DB::dbline[$i] // '';
                chomp $src;
                printf STDERR "%s: %s (%s)\n", $i, $src, $DB::dbline[$i] == 0 ? 'unbreakable' : 'breakable';
            }
        }
        elsif ($command eq 's') # dump %sub
        {
            print STDERR _dump( \%DB::sub );
        }
        elsif ($command =~ /^e\s+(.+)$/) # eval expresion
        {
            my @lsaved = ($@, $!, $,, $/, $\, $^W);
            my $expr = "package $current_package;$1";
            print STDERR "Running $expr\n";
            ($@, $!, $,, $/, $\, $^W) = @saved;
            my $result = eval $expr;
            ($@, $!, $,, $/, $\, $^W) = @lsaved;
            print STDERR "Result is $result\n";
        }
        elsif ($command eq 'f') # dump keys of %DB::dbline
        {
            print STDERR _dump( \%_perl_file_id_to_path_map );
        }
        elsif ($command eq 'g')
        {
            foreach my $frame (@{$_stack_frames})
            {
                $frame->{_single} = STEP_CONTINUE;
            }
            $DB::single = STEP_CONTINUE;
            return;
        }
        elsif ($command eq 'b') # show breakpoints, manual
        {
            print _dump( \%DB::dbline );
        }
        elsif ($command =~ /^b (\d+)$/) # set breakpoints, manual
        {
            my $line = $1;
            if ($DB::dbline[$line] == 0)
            {
                print STDERR "Line $line is unbreakable, try another one\n";
            }
            else
            {
                if ($DB::dbline{$line})
                {
                    $DB::dbline{$line} = 0;
                    print STDERR "Removed breakpoint from line $line\n";
                }
                else
                {
                    $DB::dbline{$line} = 1;
                    print STDERR "Added breakpoint to line $line\n";
                }
            }
        }
        elsif ($command =~ /^b (.+)$/) # set breakpoints from proto
        {
            _process_new_breakpoints( $1 );
        }
        elsif ($command eq 'v') # show variables
        {
            _report " * Lexical variables:\n%s", _render_variables( peek_my( 2 ) );
        }
        elsif ($command eq 'o') # over,
        {
            my $current_frame = _get_current_stack_frame;
            if ($current_frame->{is_use_block})
            {
                $current_frame->{_single} = STEP_INTO;
                $DB::single = STEP_CONTINUE;
            }
            else
            {
                $DB::single = STEP_OVER;
            }
            return;
        }
        elsif ($command =~ /^getchildren (.+)$/) # expand,
        {
            _get_reference_subelements( $1 );
        }
        elsif ($command eq 'u') # step out
        {
            my $current_frame = _get_current_stack_frame;
            if ($current_frame->{is_use_block})
            {
                $current_frame->{_single} = STEP_CONTINUE;
            }
            $DB::single = STEP_CONTINUE;

            return;
        }
        elsif ($command eq 't') # stack trace
        {
            _dump_stack && _dump_frames;
        }
        else
        {
            $DB::single = STEP_INTO;
            return;
        }
    }
}

sub _set_dbline
{
    my @caller = caller( 1 );

    ($current_package, $current_file_id, $current_line) = @caller[0, 1, 2];

    if (defined $current_file_id)
    {
        _report( <<'EOM',
%sCalling %s %s
EOM
            $frame_prefix,
            _format_caller( @caller ),
            ${^GLOBAL_PHASE} // 'unknown',
        );

        no strict 'refs';
        *DB::dbline = *{"::_<$current_file_id"};
    }
    else
    {
        _dump_stack && _dump_frames && warn "CAN'T FIND CALLER;\n";
    }
}


sub _enter_frame
{
    my ($args_ref, $old_db_single) = @_;

    my $is_use_block = 0;
    my $deparsed_block = '';

    if (ref $DB::sub)
    {
        $deparsed_block = _deparse_code( $DB::sub );
        $is_use_block = $deparsed_block =~ /require\s+[\w\:]+\s*;\s*do/si;

        _dump_stack && _dump_frames() if $trace_code_stack_and_frames;
    }

    _report $frame_prefix."Entering frame %s%s: %s%s %s-%s-%s%s",
        scalar @$_stack_frames + 1,
            $is_use_block ? '(use block)' : '',
        $DB::sub,
            scalar @$args_ref ? '('.(join ', ', @$args_ref).')' : '()',
        $DB::trace // 'undef',
        $DB::signal // 'undef',
        $old_db_single // 'undef',
            $deparsed_block ? "\n"."="x80 ."\n$deparsed_block\n"."="x80 : '',
    ;

    $frame_prefix = $frame_prefix_step x (scalar @$_stack_frames + 1);

    my $sub_file = '';
    my $sub_line = 0;

    if ($DB::sub{$DB::sub})
    {
        if ($DB::sub{$DB::sub} =~ /^(.+?):(\d+)-(\d+)$/)
        {
            $sub_file = $1;
            $sub_line = $2;
        }
        else
        {
            _report( $frame_prefix."  * Unable to parse sub data for %s, %s", $DB::sub, $DB::sub{$DB::sub} );
        }
    }
    else
    {
        _report( $frame_prefix."  * Unable to find file data for %s, %s", $DB::sub, "" #join ', ', keys %DB::sub
        );
    }

    my $new_stack_frame = {
        subname       => $DB::sub,
        args          => $args_ref,
        file          => $sub_file,
        current_line  => $sub_line,
        is_use_block  => $is_use_block,
        deparsed_code => $deparsed_block,
        _single       => $old_db_single,
    };
    unshift @$_stack_frames, $new_stack_frame;
    ($@, $!, $,, $/, $\, $^W) = @saved;
    return $new_stack_frame;
}


sub _exit_frame
{
    @saved = ($@, $!, $,, $/, $\, $^W);
    my $frame = shift @$_stack_frames;
    $frame_prefix = $frame_prefix_step x (scalar @$_stack_frames);
    _report $frame_prefix."Leaving frame %s, setting single to %s", (scalar @$_stack_frames + 1), $frame->{_single};
    $DB::single = $frame->{_single};
    ($@, $!, $,, $/, $\, $^W) = @saved;
}

sub _get_normalized_perl_file_id
{
    my ($perl_file_id) = @_;
    if ($perl_file_id =~ /_<(.+)$/)
    {
        return $1;
    }
    else
    {
        die "PANIC: Incorrect perl file id $perl_file_id";
    }

}

sub _get_perl_file_id_by_real_path
{
    my ($path) = @_;
    return exists $_paths_to_perl_file_id_map{$path} ? $_paths_to_perl_file_id_map{$path} : undef;
}


sub _get_perl_line_breakpoints_map_by_file_id
{
    my ($file_id) = @_;

    unless (defined $file_id)
    {
        _dump_stack && _dump_frames;
        die "Unitialized file id";
    }

    my $glob = $::{"_<$file_id"};
    return $glob ? *$glob{HASH} : undef;
}

sub _get_perl_line_breakpoints_map_by_real_path
{
    my ($real_path) = @_;
    my $perl_file_id = _get_perl_file_id_by_real_path( $real_path );
    return $perl_file_id ? _get_perl_line_breakpoints_map_by_file_id( $perl_file_id ) : undef;
}

sub _get_perl_source_lines_by_file_id
{
    my ($file_id) = @_;
    my $glob = $::{"_<$file_id"};
    return $glob && *$glob{ARRAY} && scalar @{*$glob{ARRAY}} ? *$glob{ARRAY} : undef;
}

sub _get_perl_source_lines_by_real_path
{
    my ($real_path) = @_;
    return _get_perl_source_lines_by_file_id( _get_perl_file_id_by_real_path( $real_path ) );
}

sub _get_real_path_by_normalized_perl_file_id
{
    my $perl_file_id = shift;

    unless ($perl_file_id)
    {
        _dump_stack && _dump_frames && die "Perl normalized file id undefined";
    }

    if (!exists $_perl_file_id_to_path_map{$perl_file_id})
    {
        no strict 'refs';
        my $real_path = _calc_real_path( ${*{"::_<$perl_file_id"}}, $perl_file_id );

        $_perl_file_id_to_path_map{$perl_file_id} = $real_path;
        $_paths_to_perl_file_id_map{$real_path} = $perl_file_id;
    }
    return $_perl_file_id_to_path_map{$perl_file_id};
}

sub _get_real_path_by_perl_file_id
{
    my ($perl_file_id) = @_;
    return _get_real_path_by_normalized_perl_file_id( _get_normalized_perl_file_id( $perl_file_id ) );
}

sub _get_loaded_breakpoints_by_real_path
{
    my ($path) = @_;
    return exists $_loaded_breakpoints{$path} ? $_loaded_breakpoints{$path} : undef;
}

sub _get_loaded_breakpoints_by_file_id
{
    my ($file_id) = @_;
    return _get_loaded_breakpoints_by_real_path( _get_real_path_by_perl_file_id( $file_id ) );
}

sub _set_breakpoint
{
    my ($path, $line, $source_lines, $breakpoints_map) = @_;

    my $event_data = {
        path => $path,
        line => $line - 1,
    };

    if ($source_lines->[$line] == 0)
    {
        _send_event( "BREAKPOINT_DENIED", $event_data );
    }
    else
    {
        $breakpoints_map->{$line} = 1;
        _send_event( "BREAKPOINT_SET", $event_data );
    }
}

sub _process_new_breakpoints
{
    my ($json_data) = @_;
    my $descriptors = _deserialize( $json_data );

    foreach my $descriptor (@$descriptors)
    {
        $descriptor->{line}++;

        _report( $frame_prefix."Processing descriptor: %s %s", $descriptor->{path}, $descriptor->{line} );

        my ($path, $line) = @$descriptor{qw/path line/};

        if ($descriptor->{remove}) # removing from loaded and set
        {
            if (exists $_loaded_breakpoints{$path} && exists $_loaded_breakpoints{$path}->{$line})
            {
                delete $_loaded_breakpoints{$path}->{$line};
            }

            if (my $breakpoints_map = _get_perl_line_breakpoints_map_by_real_path( $path ))
            {
                $breakpoints_map->{$line} = 0;
            }
        }
        else # add to loaded and set
        {
            $_loaded_breakpoints{$path} //= { };
            $_loaded_breakpoints{$path}->{$line} = $descriptor;

            if ((my $breakpoints_map = _get_perl_line_breakpoints_map_by_real_path( $path )) && (my $source_lines = _get_perl_source_lines_by_real_path( $path )))
            {
                _set_breakpoint( $path, $line, $source_lines, $breakpoints_map );
            }
        }
        # suppose is not loaded
    }
}

sub _set_break_points_for_file
{
    my ($file_id) = @_;

    my $real_path = _get_real_path_by_perl_file_id( $file_id );

    if (( my $loaded_breakpoints = _get_loaded_breakpoints_by_real_path( $real_path )) &&
        (my $perl_breakpoints_map = _get_perl_line_breakpoints_map_by_real_path( $real_path )) &&
        (my $perl_source_lines = _get_perl_source_lines_by_real_path( $real_path ))
    )
    {
        foreach my $line (keys %$loaded_breakpoints)
        {
            _set_breakpoint( $real_path, $line, $perl_source_lines, $perl_breakpoints_map );
        }
    }
}

sub _calc_real_path
{
    my $path = shift;
    my $new_filename = shift;

    my $real_path;

    if ($path !~ m{^(/|\w\:)})
    {
        print STDERR $frame_prefix."Detecting path for $path\n" if $trace_real_path;

        my $current_dir = Cwd::getcwd();

        $real_path = "$current_dir/$path";
    }
    else
    {
        $real_path = $path;
    }
    $real_path =~ s{\\}{/}g;
    print STDERR $frame_prefix."  * $new_filename real path is $real_path\n" if $trace_real_path;
    return $real_path;
}


# When the execution of your program reaches a point that can hold a breakpoint, the DB::DB() subroutine is called if
# any of the variables $DB::trace , $DB::single , or $DB::signal is true. These variables are not localizable. This
# feature is disabled when executing inside DB::DB() , including functions called from it unless $^D & (1<<30) is true.
sub step_handler
{
    return if $_internal_process;
    $_internal_process = 1;

    my $old_db_single = $DB::single;
    $DB::single = STEP_CONTINUE;
    @saved = ($@, $!, $,, $/, $\, $^W);

    printf STDERR $frame_prefix."Set dbline from step handler $DB::sub, %s\n",
        join ',', map $_ // 'undef', caller if $trace_set_db_line;
    _set_dbline();

    _report $frame_prefix."Step with %s, %s-%s-%s",
        (join ',', @_) // '',
        $DB::trace // 'undef',
        $DB::signal // 'undef',
        $old_db_single // 'undef',
    ;

    print STDERR $DB::dbline[$current_line];

    _event_handler( );

    ($@, $!, $,, $/, $\, $^W) = @saved;
    $_internal_process = 0;
    return;
}


# this pass-through flag handles quotation overload loop
sub sub_handler
{
    @saved = ($@, $!, $,, $/, $\, $^W);
    my $stack_frame;

    my $old_db_single = $DB::single;
    if (!$_internal_process)
    {
        $_internal_process = 1;

        $DB::single = STEP_CONTINUE;

        $stack_frame = _enter_frame( [ @_ ], $old_db_single );

        if ($current_package && $current_package eq 'DB')
        {
            _report "PANIC: Catched internal call";
            _dump_stack && _dump_frames();
            die;
        }

        $DB::single = $old_db_single;
        $_internal_process = 0;
    }

    my $wantarray = wantarray;

    if ($DB::single == STEP_OVER)
    {
        print STDERR $frame_prefix."Disabling step in in subcalls\n";
        $DB::single = STEP_CONTINUE;
    }
    else
    {
        printf STDERR $frame_prefix."Keeping step as %s\n", $old_db_single if $stack_frame;
    }

    if ($DB::sub eq 'DESTROY' or substr( $DB::sub, -9 ) eq '::DESTROY' or !defined $wantarray)
    {
        no strict 'refs';
        ($@, $!, $,, $/, $\, $^W) = @saved;
        &$DB::sub;

        if ($stack_frame)
        {
            _exit_frame();
        }
        else
        {
            $DB::single = $old_db_single;
        }

        return $DB::ret = undef;
    }
    if ($wantarray)
    {
        no strict 'refs';
        ($@, $!, $,, $/, $\, $^W) = @saved;
        my @result = &$DB::sub;
        if ($stack_frame)
        {
            _exit_frame();
        }
        else
        {
            $DB::single = $old_db_single;
        }
        return @DB::ret = @result;
    }
    else
    {
        no strict 'refs';
        ($@, $!, $,, $/, $\, $^W) = @saved;
        my $result = &$DB::sub;
        if ($stack_frame)
        {
            _exit_frame();
        }
        else
        {
            $DB::single = $old_db_single;
        }
        return $DB::ret = $result;
    }
}

# If the call is to an lvalue subroutine, and &DB::lsub is defined &DB::lsub (args) is called instead, otherwise
# falling back to &DB::sub (args).
sub lsub_handler: lvalue
{
    @saved = ($@, $!, $,, $/, $\, $^W);
    my $stack_frame;

    my $old_db_single = $DB::single;
    if (!$_internal_process)
    {
        $_internal_process = 1;

        $DB::single = STEP_CONTINUE;
        $stack_frame = _enter_frame( [ @_ ], $old_db_single );

        $DB::single = $old_db_single;
        $_internal_process = 0;
    }

    if ($DB::single == STEP_OVER)
    {
        print STDERR $frame_prefix."Disabling step in in subcalls\n";
        $DB::single = STEP_CONTINUE;
    }
    else
    {
        printf STDERR $frame_prefix."Keeping step as %s\n", $old_db_single if $stack_frame;
    }

    {
        no strict 'refs';
        ($@, $!, $,, $/, $\, $^W) = @saved;
        my $result = &$DB::sub;
        if ($stack_frame)
        {
            _exit_frame();
        }
        else
        {
            $DB::single = $old_db_single;
        }
        return $DB::ret = $result;
    }
}


# After each required file is compiled, but before it is executed, DB::postponed(*{"::_<$filename"}) is called if the
# subroutine DB::postponed exists. Here, the $filename is the expanded name of the required file, as found in the values
# of %INC.
#
# After each subroutine subname is compiled, the existence of $DB::postponed{subname} is checked. If this key exists,
# DB::postponed(subname) is called if the DB::postponed subroutine also exists.
sub load_handler
{
    my $old_db_single = $DB::single;
    $DB::single = STEP_CONTINUE;
    @saved = ($@, $!, $,, $/, $\, $^W);

    my $old_internal_process = $_internal_process;
    $_internal_process = 1;

    my $perl_file_id = $_[0];
    my $real_path = _get_real_path_by_perl_file_id( $perl_file_id );

    _report $frame_prefix."Loading module: %s => %s %s-%s-%s",
        $perl_file_id,
        $real_path,
        $DB::trace // 'undef',
        $DB::signal // 'undef',
        $old_db_single // 'undef',
    ;

    _set_break_points_for_file( $perl_file_id ) if $ready_to_go;

    $_internal_process = $old_internal_process;

    ($@, $!, $,, $/, $\, $^W) = @saved;
    $DB::single = $old_db_single;
}
# When execution of the program uses goto to enter a non-XS subroutine and the 0x80 bit is set in $^P , a call to
# &DB::goto is made, with $DB::sub holding the name of the subroutine being entered.
sub goto_handler
{
    return if $_internal_process;
    $_internal_process = 1;

    my $old_db_single = $DB::single;
    $DB::single = STEP_CONTINUE;

    @saved = ($@, $!, $,, $/, $\, $^W);

    _report $frame_prefix."Goto called%s from %s-%s-%s-%s",
            scalar @_ ? ' with '.(join ',', @_) : '',
        $DB::trace // 'undef',
        $DB::signal // 'undef',
        $old_db_single // 'undef',
        ${^GLOBAL_PHASE} // 'unknown',
    ;
    ($@, $!, $,, $/, $\, $^W) = @saved;
    $DB::single = $old_db_single;
    $_internal_process = 0;
}


$_local_debug_host = 'localhost';
$_local_debug_port = 12345;
$_debug_net_role = 'server';

$^P |= FLAG_REPORT_GOTO;

# http://perldoc.perl.org/perlipc.html#Sockets%3a-Client%2fServer-Communication
if ($_debug_net_role eq 'server')
{
    _report( "Listening for the debugger at %s:%s...", $_local_debug_host, $_local_debug_port );
    my $_server_socket = IO::Socket::INET->new(
        Listen    => 1,
        LocalAddr => $_local_debug_host,
        LocalPort => $_local_debug_port,
        ReuseAddr => 1,
        Proto     => 'tcp',
    ) || die "Error binding to $_local_debug_host:$_local_debug_port";
    $_debug_packed_address = accept( $_debug_socket, $_server_socket );
}
else
{
    _report( "Connecting to the debugger at %s:%s...", $_debug_server_host, $_debug_server_port );
    $_debug_socket = IO::Socket::INET->new(
        PeerAddr  => $_debug_server_host,
        LocalPort => $_debug_server_port,
        ReuseAddr => 1,
        Proto     => 'tcp',
    ) || die "Error connecting to $_debug_server_host:$_debug_server_port";
}
$_debug_socket->autoflush( 1 );

print STDERR $frame_prefix."Set dbline from main\n" if $trace_set_db_line;

_set_dbline();
push @$_stack_frames, {
        subname      => 'SCRIPT',
        args         => [ @ARGV ],
        file         => $current_file_id,
        current_line => $current_line,
        _single      => STEP_INTO,
    };

_dump_stack && _dump_frames if $trace_code_stack_and_frames;

*DB::DB = \&step_handler;
*DB::sub = \&sub_handler;
*DB::lsub = \&lsub_handler;
*DB::postponed = \&load_handler;
*DB::goto = \&goto_handler;

$_internal_process = 1;

require Cwd;
Cwd::getcwd();
require B::Deparse;
require JSON::XS;

$frame_prefix = $frame_prefix_step;

_send_event( "READY" );
_report "Waiting for breakpoints...";
my $breakpoints_data = <$_debug_socket>;
die "Connection closed" unless defined $breakpoints_data;

if ($breakpoints_data =~ /^b (.+)$/s)
{
    _process_new_breakpoints( $1 );
}
else
{
    _report( "Incorrect breakpoints data: %s", $breakpoints_data );
}

$_internal_process = 0;
$ready_to_go = 1;

$DB::single = STEP_CONTINUE;

#$DB::single = STEP_CONTINUE;

1; # End of Devel::Camelcadedb
