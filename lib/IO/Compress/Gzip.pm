
package IO::Compress::Gzip ;

require 5.004 ;

use strict ;
local ($^W) = 1; #use warnings;

use constant STATUS_OK        => 0;
use constant STATUS_ENDSTREAM => 1;
use constant STATUS_ERROR     => 2;


use IO::Compress::RawDeflate;

use Compress::Zlib 2 ;
use Compress::Zlib::Common;
use Compress::Gzip::Constants;

BEGIN
{
    if (defined &utf8::downgrade ) 
      { *noUTF8 = \&utf8::downgrade }
    else
      { *noUTF8 = sub {} }  
}

require Exporter ;

use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS $GzipError);

$VERSION = '2.000_05';
$GzipError = '' ;

@ISA    = qw(Exporter IO::Compress::RawDeflate);
@EXPORT_OK = qw( $GzipError gzip ) ;
%EXPORT_TAGS = %IO::Compress::RawDeflate::DEFLATE_CONSTANTS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

sub new
{
    my $class = shift ;

    my $obj = createSelfTiedObject($class);

    $obj->_create(undef, \$GzipError, @_);
}


sub gzip
{
    return IO::Compress::Base::_def(\$GzipError, @_);
}

sub newHeader
{
    my $self = shift ;
    return GZIP_MINIMUM_HEADER ;
}

sub getExtraParams
{
    my $self = shift ;

    use Compress::Zlib::ParseParameters;
    
    return (
            # Gzip header fields
            'Minimal'   => [Parse_boolean,   0],
            'Comment'   => [Parse_any,       undef],
            'Name'      => [Parse_any,       undef],
            'Time'      => [Parse_any,       undef],
            'TextFlag'  => [Parse_boolean,   0],
            'HeaderCRC' => [Parse_boolean,   0],
            'OS_Code'   => [Parse_unsigned,  $Compress::Zlib::gzip_os_code],
            'ExtraField'=> [Parse_string,    undef],
            'ExtraFlags'=> [Parse_any,       undef],

            # zlib behaviour
            #'Method'   => [Parse_unsigned,  Z_DEFLATED],
            'Level'     => [Parse_signed,    Z_DEFAULT_COMPRESSION],
            'Strategy'  => [Parse_signed,    Z_DEFAULT_STRATEGY],

            
        );
}


sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gzip always needs crc32
    $got->value('CRC32' => 1);

    return 1
        if $got->value('Merge') ;

    my $lax = ! $got->value('Strict') ;


    {
        if (! $got->parsed('Time') ) {
            # Modification time defaults to now.
            $got->value('Time' => time) ;
        }

        # Check that the Name & Comment don't have embedded NULLs
        # Also check that they only contain ISO 8859-1 chars.
        if ($got->parsed('Name') && defined $got->value('Name')) {
            my $name = $got->value('Name');
                
            return $self->saveErrorString(undef, "Null Character found in Name",
                                                Z_DATA_ERROR)
                if ! $lax && $name =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Name",
                                                Z_DATA_ERROR)
                if ! $lax && $name =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
        }

        if ($got->parsed('Comment') && defined $got->value('Comment')) {
            my $comment = $got->value('Comment');

            return $self->saveErrorString(undef, "Null Character found in Comment",
                                                Z_DATA_ERROR)
                if ! $lax && $comment =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Comment",
                                                Z_DATA_ERROR)
                if ! $lax && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o;
        }

        if ($got->parsed('OS_Code') ) {
            my $value = $got->value('OS_Code');

            return $self->saveErrorString(undef, "OS_Code must be between 0 and 255, got '$value'")
                if $value < 0 || $value > 255 ;
            
        }

        # gzip only supports Deflate at present
        $got->value('Method' => Z_DEFLATED) ;

        if ( ! $got->parsed('ExtraFlags')) {
            $got->value('ExtraFlags' => 2) 
                if $got->value('Level') == Z_BEST_SPEED ;
            $got->value('ExtraFlags' => 4) 
                if $got->value('Level') == Z_BEST_COMPRESSION ;
        }

        if ($got->parsed('ExtraField')) {

            my $bad = $self->parseExtraField($got, $lax) ;
            return $self->saveErrorString(undef, $bad, Z_DATA_ERROR)
                if $bad ;

            my $len = length $got->value('ExtraField') ;
            return $self->saveErrorString(undef, ExtraFieldError("Too Large"), 
                                                        Z_DATA_ERROR)
                if $len > GZIP_FEXTRA_MAX_SIZE;
        }
    }

    return 1;
}

sub mkTrailer
{
    my $self = shift ;
    return pack("V V", *$self->{Compress}->crc32(), 
                       *$self->{UnCompSize_32bit});
}

sub getInverseClass
{
    return ('IO::Uncompress::Gunzip',
                \$IO::Uncompress::Gunzip::GunzipError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $filename = shift ;

    my $defaultTime = (stat($filename))[8] ;

    $params->value('Name' => $filename)
        if ! $params->parsed('Name') ;

    $params->value('Time' => $defaultTime) 
        if ! $params->parsed('Time') ;
}


sub mkHeader
{
    my $self = shift ;
    my $param = shift ;

    # stort-circuit if a minimal header is requested.
    return GZIP_MINIMUM_HEADER if $param->value('Minimal') ;

    # METHOD
    my $method = $param->valueOrDefault('Method', GZIP_CM_DEFLATED) ;

    # FLAGS
    my $flags       = GZIP_FLG_DEFAULT ;
    $flags |= GZIP_FLG_FTEXT    if $param->value('TextFlag') ;
    $flags |= GZIP_FLG_FHCRC    if $param->value('HeaderCRC') ;
    $flags |= GZIP_FLG_FEXTRA   if $param->wantValue('ExtraField') ;
    $flags |= GZIP_FLG_FNAME    if $param->wantValue('Name') ;
    $flags |= GZIP_FLG_FCOMMENT if $param->wantValue('Comment') ;
    
    # MTIME
    my $time = $param->valueOrDefault('Time', GZIP_MTIME_DEFAULT) ;

    # EXTRA FLAGS
    my $extra_flags = $param->valueOrDefault('ExtraFlags', GZIP_XFL_DEFAULT);

    # OS CODE
    my $os_code = $param->valueOrDefault('OS_Code', GZIP_OS_DEFAULT) ;


    my $out = pack("C4 V C C", 
            GZIP_ID1,   # ID1
            GZIP_ID2,   # ID2
            $method,    # Compression Method
            $flags,     # Flags
            $time,      # Modification Time
            $extra_flags, # Extra Flags
            $os_code,   # Operating System Code
            ) ;

    # EXTRA
    if ($flags & GZIP_FLG_FEXTRA) {
        my $extra = $param->value('ExtraField') ;
        $out .= pack("v", length $extra) . $extra ;
    }

    # NAME
    if ($flags & GZIP_FLG_FNAME) {
        my $name .= $param->value('Name') ;
        $name =~ s/\x00.*$//;
        $out .= $name ;
        # Terminate the filename with NULL unless it already is
        $out .= GZIP_NULL_BYTE 
            if !length $name or
               substr($name, 1, -1) ne GZIP_NULL_BYTE ;
    }

    # COMMENT
    if ($flags & GZIP_FLG_FCOMMENT) {
        my $comment .= $param->value('Comment') ;
        $comment =~ s/\x00.*$//;
        $out .= $comment ;
        # Terminate the comment with NULL unless it already is
        $out .= GZIP_NULL_BYTE
            if ! length $comment or
               substr($comment, 1, -1) ne GZIP_NULL_BYTE;
    }

    # HEADER CRC
    $out .= pack("v", crc32($out) & 0x00FF ) if $param->value('HeaderCRC') ;

    noUTF8($out);

    return $out ;
}

sub ExtraFieldError
{
    return "Error with ExtraField Parameter: $_[0]" ;
}

sub validateExtraFieldPair
{
    my $pair = shift ;
    my $lax  = shift ;

    return ExtraFieldError("Not an array ref")
        unless ref $pair &&  ref $pair eq 'ARRAY';

    return ExtraFieldError("SubField must have two parts")
        unless @$pair == 2 ;

    return ExtraFieldError("SubField ID is a reference")
        if ref $pair->[0] ;

    return ExtraFieldError("SubField Data is a reference")
        if ref $pair->[1] ;

    # ID is exactly two chars   
    return ExtraFieldError("SubField ID not two chars long")
        unless length $pair->[0] == GZIP_FEXTRA_SUBFIELD_ID_SIZE ;

    # Check that the 2nd byte of the ID isn't 0    
    return ExtraFieldError("SubField ID 2nd byte is 0x00")
        if ! $lax && substr($pair->[0], 1, 1) eq "\x00" ;

    return ExtraFieldError("SubField Data too long")
        if length $pair->[1] > GZIP_FEXTRA_SUBFIELD_MAX_SIZE ;


    return undef ;
}

sub parseExtra
{
    my $data = shift ;
    my $lax = shift ;

    return undef
        if $lax ;

    my $XLEN = length $data ;

    return ExtraFieldError("Too Large")
        if $XLEN > GZIP_FEXTRA_MAX_SIZE;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return ExtraFieldError("FEXTRA Body")
            if $offset + GZIP_FEXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, GZIP_FEXTRA_SUBFIELD_ID_SIZE);    
        $offset += GZIP_FEXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            GZIP_FEXTRA_SUBFIELD_LEN_SIZE));
        $offset += GZIP_FEXTRA_SUBFIELD_LEN_SIZE ;

        return ExtraFieldError("FEXTRA Body")
            if $offset + $subLen > $XLEN ;

        my $bad = validateExtraFieldPair( [$id, 
                                            substr($data, $offset, $subLen)], $lax );
        return $bad if $bad ;

        $offset += $subLen ;
    }
        
    return undef ;
}

sub parseExtraField
{
    my $self = shift ;
    my $got  = shift ;
    my $lax  = shift ;

    # ExtraField can be any of
    #
    #    -ExtraField => $data
    #    -ExtraField => [$id1, $data1,
    #                    $id2, $data2]
    #                     ...
    #                   ]
    #    -ExtraField => [ [$id1 => $data1],
    #                     [$id2 => $data2],
    #                     ...
    #                   ]
    #    -ExtraField => { $id1 => $data1,
    #                     $id2 => $data2,
    #                     ...
    #                   }

    
    return undef
        unless $got->parsed('ExtraField') ;

    return parseExtra($got->value('ExtraField'), $lax)
        unless ref $got->value('ExtraField') ;

    my $data = $got->value('ExtraField');
    my $out = '' ;

    if (ref $data eq 'ARRAY') {    
        if (ref $data->[0]) {

            foreach my $pair (@$data) {
                return ExtraFieldError("Not list of lists")
                    unless ref $pair eq 'ARRAY' ;

                my $bad = validateExtraFieldPair($pair, $lax) ;
                return $bad if $bad ;

                $out .= $pair->[0] . pack("v", length $pair->[1]) . 
                        $pair->[1] ;
            }   
        }   
        else {
            return ExtraFieldError("Not even number of elements")
                unless @$data % 2  == 0;

            for (my $ix = 0; $ix <= length(@$data) -1 ; $ix += 2) {
                my $bad = validateExtraFieldPair([$data->[$ix], $data->[$ix+1]], $lax) ;
                return $bad if $bad ;

                $out .= $data->[$ix] . pack("v", length $data->[$ix+1]) . 
                        $data->[$ix+1] ;
            }   
        }
    }   
    elsif (ref $data eq 'HASH') {    
        while (my ($id, $info) = each %$data) {
            my $bad = validateExtraFieldPair([$id, $info], $lax);
            return $bad if $bad ;

            $out .= $id .  pack("v", length $info) . $info ;
        }   
    }   
    else {
        return ExtraFieldError("Not a scalar, array ref or hash ref") ;
    }

    $got->value('ExtraField' => $out);

    return undef;
}

sub mkFinalTrailer
{
    return '';
}

1; 

__END__

=head1 NAME

IO::Gzip     - Perl interface to write RFC 1952 files/buffers

=head1 SYNOPSIS

    use IO::Gzip qw(gzip $GzipError) ;


    my $status = gzip $input => $output [,OPTS] 
        or die "gzip failed: $GzipError\n";

    my $z = new IO::Gzip $output [,OPTS]
        or die "gzip failed: $GzipError\n";

    $z->print($string);
    $z->printf($format, $string);
    $z->write($string);
    $z->syswrite($string [, $length, $offset]);
    $z->flush();
    $z->tell();
    $z->eof();
    $z->seek($position, $whence);
    $z->binmode();
    $z->fileno();
    $z->newStream();
    $z->deflateParams();
    $z->close() ;

    $GzipError ;

    # IO::File mode

    print $z $string;
    printf $z $format, $string;
    syswrite $z, $string [, $length, $offset];
    flush $z, ;
    tell $z
    eof $z
    seek $z, $position, $whence
    binmode $z
    fileno $z
    close $z ;
    

=head1 DESCRIPTION



B<WARNING -- This is a Beta release>. 

=over 5

=item * DO NOT use in production code.

=item * The documentation is incomplete in places.

=item * Parts of the interface defined here are tentative.

=item * Please report any problems you find.

=back



This module provides a Perl interface that allows writing compressed
data to files or buffer as defined in RFC 1952.


All the gzip headers defined in RFC 1952 can be created using
this module.




For reading RFC 1952 files/buffers, see the companion module 
L<IO::Gunzip|IO::Gunzip>.


=head1 Functional Interface

A top-level function, C<gzip>, is provided to carry out "one-shot"
compression between buffers and/or files. For finer control over the compression process, see the L</"OO Interface"> section.

    use IO::Gzip qw(gzip $GzipError) ;

    gzip $input => $output [,OPTS] 
        or die "gzip failed: $GzipError\n";

    gzip \%hash [,OPTS] 
        or die "gzip failed: $GzipError\n";

The functional interface needs Perl5.005 or better.


=head2 gzip $input => $output [, OPTS]

If the first parameter is not a hash reference C<gzip> expects
at least two parameters, C<$input> and C<$output>.

=head3 The C<$input> parameter

The parameter, C<$input>, is used to define the source of
the uncompressed data. 

It can take one of the following forms:

=over 5

=item A filename

If the C<$input> parameter is a simple scalar, it is assumed to be a
filename. This file will be opened for reading and the input data
will be read from it.

=item A filehandle

If the C<$input> parameter is a filehandle, the input data will be
read from it.
The string '-' can be used as an alias for standard input.

=item A scalar reference 

If C<$input> is a scalar reference, the input data will be read
from C<$$input>.

=item An array reference 

If C<$input> is an array reference, the input data will be read from each
element of the array in turn. The action taken by C<gzip> with
each element of the array will depend on the type of data stored
in it. You can mix and match any of the types defined in this list,
excluding other array or hash references. 
The complete array will be walked to ensure that it only
contains valid data types before any data is compressed.

=item An Input FileGlob string

If C<$input> is a string that is delimited by the characters "<" and ">"
C<gzip> will assume that it is an I<input fileglob string>. The
input is the list of files that match the fileglob.

If the fileglob does not match any files ...

See L<File::GlobMapper|File::GlobMapper> for more details.


=back

If the C<$input> parameter is any other type, C<undef> will be returned.



In addition, if C<$input> is a simple filename, the default values for
two of the gzip header fields created by this function will be sourced
from that file -- the NAME gzip header field will be populated with
the filename itself, and the MTIME header field will be set to the
modification time of the file.
The intention here is to mirror part of the behavior of the gzip
executable.
If you do not want to use these defaults they can be overridden by
explicitly setting the C<Name> and C<Time> options.



=head3 The C<$output> parameter

The parameter C<$output> is used to control the destination of the
compressed data. This parameter can take one of these forms.

=over 5

=item A filename

If the C<$output> parameter is a simple scalar, it is assumed to be a filename.
This file will be opened for writing and the compressed data will be
written to it.

=item A filehandle

If the C<$output> parameter is a filehandle, the compressed data will
be written to it.  
The string '-' can be used as an alias for standard output.


=item A scalar reference 

If C<$output> is a scalar reference, the compressed data will be stored
in C<$$output>.


=item A Hash Reference

If C<$output> is a hash reference, the compressed data will be written
to C<$output{$input}> as a scalar reference.

When C<$output> is a hash reference, C<$input> must be either a filename or
list of filenames. Anything else is an error.


=item An Array Reference

If C<$output> is an array reference, the compressed data will be pushed
onto the array.

=item An Output FileGlob

If C<$output> is a string that is delimited by the characters "<" and ">"
C<gzip> will assume that it is an I<output fileglob string>. The
output is the list of files that match the fileglob.

When C<$output> is an fileglob string, C<$input> must also be a fileglob
string. Anything else is an error.

=back

If the C<$output> parameter is any other type, C<undef> will be returned.

=head2 gzip \%hash [, OPTS]

If the first parameter is a hash reference, C<\%hash>, this will be used to
define both the source of uncompressed data and to control where the
compressed data is output. Each key/value pair in the hash defines a
mapping between an input filename, stored in the key, and an output
file/buffer, stored in the value. Although the input can only be a filename,
there is more flexibility to control the destination of the compressed
data. This is determined by the type of the value. Valid types are

=over 5

=item undef

If the value is C<undef> the compressed data will be written to the
value as a scalar reference.

=item A filename

If the value is a simple scalar, it is assumed to be a filename. This file will
be opened for writing and the compressed data will be written to it.

=item A filehandle

If the value is a filehandle, the compressed data will be
written to it. 
The string '-' can be used as an alias for standard output.


=item A scalar reference 

If the value is a scalar reference, the compressed data will be stored
in the buffer that is referenced by the scalar.


=item A Hash Reference

If the value is a hash reference, the compressed data will be written
to C<$hash{$input}> as a scalar reference.

=item An Array Reference

If C<$output> is an array reference, the compressed data will be pushed
onto the array.

=back

Any other type is a error.

=head2 Notes

When C<$input> maps to multiple files/buffers and C<$output> is a single
file/buffer the compressed input files/buffers will all be stored in
C<$output> as a single compressed stream.



=head2 Optional Parameters

Unless specified below, the optional parameters for C<gzip>,
C<OPTS>, are the same as those used with the OO interface defined in the
L</"Constructor Options"> section below.

=over 5

=item AutoClose =E<gt> 0|1

This option applies to any input or output data streams to C<gzip>
that are filehandles.

If C<AutoClose> is specified, and the value is true, it will result in all
input and/or output filehandles being closed once C<gzip> has
completed.

This parameter defaults to 0.



=item -Append =E<gt> 0|1

TODO


=back



=head2 Examples

To read the contents of the file C<file1.txt> and write the compressed
data to the file C<file1.txt.gz>.

    use strict ;
    use warnings ;
    use IO::Gzip qw(gzip $GzipError) ;

    my $input = "file1.txt";
    gzip $input => "$input.gz"
        or die "gzip failed: $GzipError\n";


To read from an existing Perl filehandle, C<$input>, and write the
compressed data to a buffer, C<$buffer>.

    use strict ;
    use warnings ;
    use IO::Gzip qw(gzip $GzipError) ;
    use IO::File ;

    my $input = new IO::File "<file1.txt"
        or die "Cannot open 'file1.txt': $!\n" ;
    my $buffer ;
    gzip $input => \$buffer 
        or die "gzip failed: $GzipError\n";

To compress all files in the directory "/my/home" that match "*.txt"
and store the compressed data in the same directory

    use strict ;
    use warnings ;
    use IO::Gzip qw(gzip $GzipError) ;

    gzip '</my/home/*.txt>' => '<*.gz>'
        or die "gzip failed: $GzipError\n";

and if you want to compress each file one at a time, this will do the trick

    use strict ;
    use warnings ;
    use IO::Gzip qw(gzip $GzipError) ;

    for my $input ( glob "/my/home/*.txt" )
    {
        my $output = "$input.gz" ;
        gzip $input => $output 
            or die "Error compressing '$input': $GzipError\n";
    }


=head1 OO Interface

=head2 Constructor

The format of the constructor for C<IO::Gzip> is shown below

    my $z = new IO::Gzip $output [,OPTS]
        or die "IO::Gzip failed: $GzipError\n";

It returns an C<IO::Gzip> object on success and undef on failure. 
The variable C<$GzipError> will contain an error message on failure.

If you are running Perl 5.005 or better the object, C<$z>, returned from 
IO::Gzip can be used exactly like an L<IO::File|IO::File> filehandle. 
This means that all normal output file operations can be carried out 
with C<$z>. 
For example, to write to a compressed file/buffer you can use either of 
these forms

    $z->print("hello world\n");
    print $z "hello world\n";

The mandatory parameter C<$output> is used to control the destination
of the compressed data. This parameter can take one of these forms.

=over 5

=item A filename

If the C<$output> parameter is a simple scalar, it is assumed to be a
filename. This file will be opened for writing and the compressed data
will be written to it.

=item A filehandle

If the C<$output> parameter is a filehandle, the compressed data will be
written to it.
The string '-' can be used as an alias for standard output.


=item A scalar reference 

If C<$output> is a scalar reference, the compressed data will be stored
in C<$$output>.

=back

If the C<$output> parameter is any other type, C<IO::Gzip>::new will
return undef.

=head2 Constructor Options

C<OPTS> is any combination of the following options:

=over 5

=item -AutoClose =E<gt> 0|1

This option is only valid when the C<$output> parameter is a filehandle. If
specified, and the value is true, it will result in the C<$output> being closed
once either the C<close> method is called or the C<IO::Gzip> object is
destroyed.

This parameter defaults to 0.

=item -Append =E<gt> 0|1

Opens C<$output> in append mode. 

The behaviour of this option is dependant on the type of C<$output>.

=over 5

=item * A Buffer

If C<$output> is a buffer and C<Append> is enabled, all compressed data will be
append to the end if C<$output>. Otherwise C<$output> will be cleared before
any data is written to it.

=item * A Filename

If C<$output> is a filename and C<Append> is enabled, the file will be opened
in append mode. Otherwise the contents of the file, if any, will be truncated
before any compressed data is written to it.

=item * A Filehandle

If C<$output> is a filehandle, the file pointer will be positioned to the end
of the file via a call to C<seek> before any compressed data is written to it.
Otherwise the file pointer will not be moved.

=back

This parameter defaults to 0.

=item -Merge =E<gt> 0|1

This option is used to compress input data and append it to an existing
compressed data stream in C<$output>. The end result is a single compressed
data stream stored in C<$output>. 



It is a fatal error to attempt to use this option when C<$output> is not an RFC
1952 data stream.



There are a number of other limitations with the C<Merge> option:

=over 5 

=item 1

This module needs to have been built with zlib 1.2.1 or better to work. A fatal
error will be thrown if C<Merge> is used with an older version of zlib.  

=item 2

If C<$output> is a file or a filehandle, it must be seekable.

=back


This parameter defaults to 0.

=item -Level 

Defines the compression level used by zlib. The value should either be
a number between 0 and 9 (0 means no compression and 9 is maximum
compression), or one of the symbolic constants defined below.

   Z_NO_COMPRESSION
   Z_BEST_SPEED
   Z_BEST_COMPRESSION
   Z_DEFAULT_COMPRESSION

The default is Z_DEFAULT_COMPRESSION.

Note, these constants are not imported by C<IO::Gzip> by default.

    use IO::Gzip qw(:strategy);
    use IO::Gzip qw(:constants);
    use IO::Gzip qw(:all);

=item -Strategy 

Defines the strategy used to tune the compression. Use one of the symbolic
constants defined below.

   Z_FILTERED
   Z_HUFFMAN_ONLY
   Z_RLE
   Z_FIXED
   Z_DEFAULT_STRATEGY

The default is Z_DEFAULT_STRATEGY.





=item -Mimimal =E<gt> 0|1

If specified, this option will force the creation of the smallest possible
compliant gzip header (which is exactly 10 bytes long) as defined in
RFC 1952.

See the section titled "Compliance" in RFC 1952 for a definition 
of the values used for the fields in the gzip header.

All other parameters that control the content of the gzip header will
be ignored if this parameter is set to 1.

This parameter defaults to 0.

=item -Comment =E<gt> $comment

Stores the contents of C<$comment> in the COMMENT field in
the gzip header.
By default, no comment field is written to the gzip file.

If the C<-Strict> option is enabled, the comment can only consist of ISO
8859-1 characters plus line feed.

If the C<-Strict> option is disabled, the comment field can contain any
character except NULL. If any null characters are present, the field
will be truncated at the first NULL.

=item -Name =E<gt> $string

Stores the contents of C<$string> in the gzip NAME header field. If
C<Name> is not specified, no gzip NAME field will be created.

If the C<-Strict> option is enabled, C<$string> can only consist of ISO
8859-1 characters.

If C<-Strict> is disabled, then C<$string> can contain any character
except NULL. If any null characters are present, the field will be
truncated at the first NULL.

=item -Time =E<gt> $number

Sets the MTIME field in the gzip header to $number.

This field defaults to the time the C<IO::Gzip> object was created
if this option is not specified.

=item -TextFlag =E<gt> 0|1

This parameter controls the setting of the FLG.FTEXT bit in the gzip header. It
is used to signal that the data stored in the gzip file/buffer is probably
text.

The default is 0. 

=item -HeaderCRC =E<gt> 0|1

When true this parameter will set the FLG.FHCRC bit to 1 in the gzip header and
set the CRC16 header field to the CRC of the complete gzip header except the
CRC16 field itself.

B<Note> that gzip files created with the C<HeaderCRC> flag set to 1 cannot be
read by most, if not all, of the the standard gunzip utilities, most notably
gzip version 1.2.4. You should therefore avoid using this option if you want to
maximise the portability of your gzip files.

This parameter defaults to 0.

=item -OS_Code =E<gt> $value

Stores C<$value> in the gzip OS header field. A number between 0 and
255 is valid.

If not specified, this parameter defaults to the OS code of the Operating
System this module was built on. The value 3 is used as a catch-all for all
Unix variants and unknown Operating Systems.

=item -ExtraField =E<gt> $data

This parameter allows additional metadata to be stored in the ExtraField in the
gzip header. An RFC1952 compliant ExtraField consists of zero or more
subfields. Each subfield consists of a two byte header followed by the subfield
data.

The list of subfields can be supplied in any of the following formats

    -ExtraField => [$id1, $data1,
                    $id2, $data2,
                     ...
                   ]
    -ExtraField => [ [$id1 => $data1],
                     [$id2 => $data2],
                     ...
                   ]
    -ExtraField => { $id1 => $data1,
                     $id2 => $data2,
                     ...
                   }

Where C<$id1>, C<$id2> are two byte subfield ID's. The second byte of
the ID cannot be 0, unless the C<Strict> option has been disabled.

If you use the hash syntax, you have no control over the order in which
the ExtraSubFields are stored, plus you cannot have SubFields with
duplicate ID.

Alternatively the list of subfields can by supplied as a scalar, thus

    -ExtraField => $rawdata

If you use the raw format, and the C<Strict> option is enabled,
C<IO::Gzip> will check that C<$rawdata> consists of zero or more
conformant sub-fields. When C<Strict> is disabled, C<$rawdata> can
consist of any arbitrary byte stream.

The maximum size of the Extra Field 65535 bytes.

=item -ExtraFlags =E<gt> $value

Sets the XFL byte in the gzip header to C<$value>.

If this option is not present, the value stored in XFL field will be determined
by the setting of the C<Level> option.

If C<Level =E<gt> Z_BEST_SPEED> has been specified then XFL is set to 2.
If C<Level =E<gt> Z_BEST_COMPRESSION> has been specified then XFL is set to 4.
Otherwise XFL is set to 0.



=item -Strict =E<gt> 0|1



C<Strict> will optionally police the values supplied with other options
to ensure they are compliant with RFC1952.

This option is enabled by default.

If C<Strict> is enabled the following behavior will be policed:

=over 5

=item * 

The value supplied with the C<Name> option can only contain ISO 8859-1
characters.

=item * 

The value supplied with the C<Comment> option can only contain ISO 8859-1
characters plus line-feed.

=item *

The values supplied with the C<-Name> and C<-Comment> options cannot
contain multiple embedded nulls.

=item * 

If an C<ExtraField> option is specified and it is a simple scalar,
it must conform to the sub-field structure as defined in RFC1952.

=item * 

If an C<ExtraField> option is specified the second byte of the ID will be
checked in each subfield to ensure that it does not contain the reserved
value 0x00.

=back

When C<Strict> is disabled the following behavior will be policed:

=over 5

=item * 

The value supplied with C<-Name> option can contain
any character except NULL.

=item * 

The value supplied with C<-Comment> option can contain any character
except NULL.

=item *

The values supplied with the C<-Name> and C<-Comment> options can contain
multiple embedded nulls. The string written to the gzip header will
consist of the characters up to, but not including, the first embedded
NULL.

=item * 

If an C<ExtraField> option is specified and it is a simple scalar, the
structure will not be checked. The only error is if the length is too big.

=item * 

The ID header in an C<ExtraField> sub-field can consist of any two bytes.

=back



=back

=head2 Examples

TODO

=head1 Methods 

=head2 print

Usage is

    $z->print($data)
    print $z $data

Compresses and outputs the contents of the C<$data> parameter. This
has the same behavior as the C<print> built-in.

Returns true if successful.

=head2 printf

Usage is

    $z->printf($format, $data)
    printf $z $format, $data

Compresses and outputs the contents of the C<$data> parameter.

Returns true if successful.

=head2 syswrite

Usage is

    $z->syswrite $data
    $z->syswrite $data, $length
    $z->syswrite $data, $length, $offset

    syswrite $z, $data
    syswrite $z, $data, $length
    syswrite $z, $data, $length, $offset

Compresses and outputs the contents of the C<$data> parameter.

Returns the number of uncompressed bytes written, or C<undef> if
unsuccessful.

=head2 write

Usage is

    $z->write $data
    $z->write $data, $length
    $z->write $data, $length, $offset

Compresses and outputs the contents of the C<$data> parameter.

Returns the number of uncompressed bytes written, or C<undef> if
unsuccessful.

=head2 flush

Usage is

    $z->flush;
    $z->flush($flush_type);
    flush $z ;
    flush $z $flush_type;

Flushes any pending compressed data to the output file/buffer.

This method takes an optional parameter, C<$flush_type>, that controls
how the flushing will be carried out. By default the C<$flush_type>
used is C<Z_FINISH>. Other valid values for C<$flush_type> are
C<Z_NO_FLUSH>, C<Z_SYNC_FLUSH>, C<Z_FULL_FLUSH> and C<Z_BLOCK>. It is
strongly recommended that you only set the C<flush_type> parameter if
you fully understand the implications of what it does - overuse of C<flush>
can seriously degrade the level of compression achieved. See the C<zlib>
documentation for details.

Returns true on success.


=head2 tell

Usage is

    $z->tell()
    tell $z

Returns the uncompressed file offset.

=head2 eof

Usage is

    $z->eof();
    eof($z);



Returns true if the C<close> method has been called.



=head2 seek

    $z->seek($position, $whence);
    seek($z, $position, $whence);




Provides a sub-set of the C<seek> functionality, with the restriction
that it is only legal to seek forward in the output file/buffer.
It is a fatal error to attempt to seek backward.

Empty parts of the file/buffer will have NULL (0x00) bytes written to them.



The C<$whence> parameter takes one the usual values, namely SEEK_SET,
SEEK_CUR or SEEK_END.

Returns 1 on success, 0 on failure.

=head2 binmode

Usage is

    $z->binmode
    binmode $z ;

This is a noop provided for completeness.

=head2 fileno

    $z->fileno()
    fileno($z)

If the C<$z> object is associated with a file, this method will return
the underlying filehandle.

If the C<$z> object is is associated with a buffer, this method will
return undef.

=head2 close

    $z->close() ;
    close $z ;



Flushes any pending compressed data and then closes the output file/buffer. 



For most versions of Perl this method will be automatically invoked if
the IO::Gzip object is destroyed (either explicitly or by the
variable with the reference to the object going out of scope). The
exceptions are Perl versions 5.005 through 5.00504 and 5.8.0. In
these cases, the C<close> method will be called automatically, but
not until global destruction of all live objects when the program is
terminating.

Therefore, if you want your scripts to be able to run on all versions
of Perl, you should call C<close> explicitly and not rely on automatic
closing.

Returns true on success, otherwise 0.

If the C<AutoClose> option has been enabled when the IO::Gzip
object was created, and the object is associated with a file, the
underlying file will also be closed.




=head2 newStream

Usage is

    $z->newStream

TODO

=head2 deflateParams

Usage is

    $z->deflateParams

TODO

=head1 Importing 

A number of symbolic constants are required by some methods in 
C<IO::Gzip>. None are imported by default.

=over 5

=item :all

Imports C<gzip>, C<$GzipError> and all symbolic
constants that can be used by C<IO::Gzip>. Same as doing this

    use IO::Gzip qw(gzip $GzipError :constants) ;

=item :constants

Import all symbolic constants. Same as doing this

    use IO::Gzip qw(:flush :level :strategy) ;

=item :flush

These symbolic constants are used by the C<flush> method.

    Z_NO_FLUSH
    Z_PARTIAL_FLUSH
    Z_SYNC_FLUSH
    Z_FULL_FLUSH
    Z_FINISH
    Z_BLOCK


=item :level

These symbolic constants are used by the C<Level> option in the constructor.

    Z_NO_COMPRESSION
    Z_BEST_SPEED
    Z_BEST_COMPRESSION
    Z_DEFAULT_COMPRESSION


=item :strategy

These symbolic constants are used by the C<Strategy> option in the constructor.

    Z_FILTERED
    Z_HUFFMAN_ONLY
    Z_RLE
    Z_FIXED
    Z_DEFAULT_STRATEGY

=back

For 

=head1 EXAMPLES

TODO






=head1 SEE ALSO

L<Compress::Zlib>, L<IO::Gunzip>, L<IO::Deflate>, L<IO::Inflate>, L<IO::RawDeflate>, L<IO::RawInflate>, L<IO::AnyInflate>

L<Compress::Zlib::FAQ|Compress::Zlib::FAQ>

L<File::GlobMapper|File::GlobMapper>, L<Archive::Tar|Archive::Zip>,
L<IO::Zlib|IO::Zlib>

For RFC 1950, 1951 and 1952 see 
F<http://www.faqs.org/rfcs/rfc1950.html>,
F<http://www.faqs.org/rfcs/rfc1951.html> and
F<http://www.faqs.org/rfcs/rfc1952.html>

The primary site for the gzip program is F<http://www.gzip.org>.

=head1 AUTHOR

The I<IO::Gzip> module was written by Paul Marquess,
F<pmqs@cpan.org>. The latest copy of the module can be
found on CPAN in F<modules/by-module/Compress/Compress-Zlib-x.x.tar.gz>.

The I<zlib> compression library was written by Jean-loup Gailly
F<gzip@prep.ai.mit.edu> and Mark Adler F<madler@alumni.caltech.edu>.

The primary site for the I<zlib> compression library is
F<http://www.zlib.org>.

=head1 MODIFICATION HISTORY

See the Changes file.

=head1 COPYRIGHT AND LICENSE
 

Copyright (c) 2005 Paul Marquess. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.




