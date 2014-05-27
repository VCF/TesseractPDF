package Image::OCR::TesseractPDF;

=head1 DESCRIPTION

TesseractPDF is designed to produce searchable PDF documents from
scanned images. It contains no OCR code itself, but instead uses
system calls to L<tesseract|https://code.google.com/p/tesseract-ocr/>
to perform optical character recognition of the image. This module
then merges the original image with the text that tesseract has
extracted, to create a PDF that faithfully represents the original
document (via the scanned image) but also contains the OCR'ed text,
for searching, copying or exporting.

The scanned images will be placed "in the background" of the PDF, and
the text will be overlain as 100% transparent characters. This allows
the scanned image to be viewed "unhindered", while allowing the text
to be highlighted and copied with the mouse. Most PDF viewers should
also expose such "hidden" text by selecting all ("Ctrl-A").

The rationale here is that while tesseract is an excellent program,
OCR remains a difficult computational problem, and mistakes are
made. Preserving the original image allows any extracted text to be
validated and corrected (by the human reader). It also preserves
non-character data such as figures and pictures.

PDF manipulations are done using L<PDF::API2>. hOCR parsing uses
L<XML::DOM>. Also requires L<BMS::Utilities>, which at the moment can
be found at
L<https://github.com/VCF/MapLoc/blob/master/BMS/Utilities.pm>

=head2 NOTE - Web App Security

I've made a half-hearted attempt to sanitize user input, but it has
not been a focus, and system calls using user-provided values are made
in several subroutines.

     DO NOT USE THIS MODULE WITH POTENTIALLY TAINTED INPUT!

=head1 SYNOPSIS

 # Instantiate a new object:
 my $tpdf = Image::OCR::TesseractPDF->new
    ( -scandpi => 400, # Resolution of scanned image
      -pdfdpi  => 150, # Down-sampled resolution to use in PDF
      -maxfont => 15,  # Discard any characters over this size
      -minfont => 5,   # Discard characters smaller than this
      -debug   => 0 );

 # ImageMagick can be automatically invoked for pre-OCR cleaning:
 # (The trailing 'png' is recognized by the module and removed)
 $tpdf->clean_params('-despeckle -sigmoidal-contrast 10x50% png');
 
 # Certain documents produce predictable junk characters. Callbacks
 # can be defined to filter out anticipated noise prior to creating
 # the PDF. The callback below intercepts a pattern I found in one of
 # my bills - dotted lines were interpreted as runs of small
 # characters, with "i", ":", "." and "f" dominating the
 
 $tpdf->line_filter( sub {
    my $self = shift;
    my $lineDat = shift;
    my $txt     = $lineDat->{line};
    return "Empty line" unless (defined $txt);
    my $len = length($txt);
    $txt =~ s/[i:.f]+//g;
    return "Likely dotted line" if (length($txt) / $len >= 0.2);
    return 0;
 });
 
 my $dir = "/some/place/";
 $tpdf->add_image("$dir/image1.tiff");
 $tpdf->add_image("$dir/image2.tiff");
 $tpdf->add_image("$dir/image3.tiff");
 
 $tpdf->ocr();
 
 # Raw OCR text is available:
 my $txt = $tpdf->text();

 # Save the document:
 $tpdf->saveas("$dir/document.pdf");

=head2 NOTE - OCR Observations

  * Bear in mind that this module is a I<wrapper> around Tesseract. I
    have limited capacity to improve its operation. The project is
    being actively developed as of 2014, however, and appears to be
    continuously improving.

  * Skew, the rotation of the document away from perfectly horizontal
    or vertical, has a MAJOR impact on OCR quality. This can be
    corrected manually in many image editors. I have explored
    automated mechanisms but have not yet found a solution for Linux.

  * Colored backgrounds appear to hinder text recognition.

  * I suspect many OCR challenges can be improved with
    pre-processing. The clean_params() method allows ImageMagick to be
    integrated into a work flow; See the documentation for available
    tools:

    L<http://www.imagemagick.org/script/command-line-options.php>

=head1 AUTHOR

Charles Tilford <podmail@biocode.fastmail.fm>

//Subject __must__ include 'Perl' to escape mail filters//

=head1 LICENSE

Copyright 2014 Charles Tilford

 http://mit-license.org/

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
  ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

=cut

use strict;
use PDF::API2;
use XML::DOM;
use base qw( BMS::Utilities );

sub new {
    my $class = shift;
    my $self = {
        SFX        => "",
        SCANDPI    => 400,
        PDFDPI     => 150,
        JPGQUAL    => 80,
        PAGES      => [],
        DEBUG_MODE => 0,
        MODE       => "Word",
        FONT       => 'Helvetica-Bold',
        TEXT       => "",
        MINFTPT    => 5,
        WORKDIR    => "TesseractPDF",
        ENGINE     => "Tesseract",
    };
    bless $self, $class;
    my $args = $self->parseparams( @_ );
    $self->engine( $args->{ENGINE} );
    # Bootstrap the font to set the values for the scratch object:
    $self->font_name( $self->font_name( $args->{FONT}) );
    $self->scan_resolution( $args->{SCANDPI} );
    $self->pdf_resolution( $args->{PDFDPI} );
    $self->jpg_quality( $args->{JPGQUAL} );
    $self->min_font_pt( $args->{MINFONT} );
    $self->max_font_pt( $args->{MAXFONT} );
    $self->debug_mode( $args->{DEBUG} );
    # die $self->branch(-ref => $self, -maxany => 50, -skipkey => ['SCRATCH', 'PAGES','PDFAPI2','EXTGRP']);
    return $self;
}

# This is an arbitrary font size used at first when calculating the actual
# size to place on a scanned document:
our $tryFnt = 10;

sub saveas {
    my $self = shift;
    my $file = shift;
    $self->api2->saveas($file);
}

sub debug_mode {
    my $self = shift;
    if (defined $_[0]) {
        $self->{DEBUG_MODE} = $_[0] ? 1 : 0;
    }
    return $self->{DEBUG_MODE};
}

sub api2 {
    my $self = shift;
    unless ($self->{PDFAPI2}) {
        $self->{PDFAPI2} = PDF::API2->new();
    }
    return $self->{PDFAPI2};
}

sub engine {
    my $self = shift;
    if (my $nv = shift) {
        if ($nv =~ /tess/i) {
            $self->{ENGINE} = 'Tesseract'
        } elsif ($nv =~ /cune/i) {
            $self->{ENGINE} = 'Cuneiform'
        } else {
            $self->error("Could not interpret OCR engine '$nv'");
        }
    }
    return $self->{ENGINE};
}

sub work_dir {
    my $self = shift;
    if (defined $_[0]) {
        my $nv = $_[0];
        if ($nv =~ /[\\\"]/) {
            $self->error("work_dir() can not have slashes or quotes");
        } else {
            $nv =~ s/\/+$//;
            $self->{WORKDIR} = $nv;
        }
    }
    return $self->{WORKDIR};
}

sub clean_params {
    my $self = shift;
    my $nv   = shift;
    if (defined $nv) {
        if ($nv) {
            if ($nv =~ /[\"\\]/) {
                $self->error("Can not set parameters with quotes or slashes",
                             $nv);
            } else {
                $self->{CLEANPARAM} = $nv;
            }
        } else {
            delete $self->{CLEANPARAM};
        }
    }
    return $self->{CLEANPARAM};
}

sub extended_graphics {
    my $self = shift;
    unless ($self->{EXTGRP}) {
        my $eg = $self->{EXTGRP} = $self->api2->egstate();
        $eg->transparency(1);
    }
    return $self->{EXTGRP};
}

sub text { return shift->{TEXT}; }

sub font_name {
    my $self = shift;
    if (my $nv = shift) {
        $self->{FONT} = $nv;
        my ($scTxt, $scPdf) = $self->scratch();
        my $scFont   = $scPdf->corefont($nv);
        $scTxt->font($scFont, $tryFnt);
    }
    return $self->{FONT};
}

sub line_filter {
    my $self = shift;
    if (defined $_[0]) {
        my $nv = $_[0];
        if ($nv) {
            my $r = ref($nv);
            if ($r eq 'CODE') {
                $self->{LINE_FILTER} = $nv;
            } else {
                $self->error("line_filter() should be a code reference");
            }
        } else {
            delete $self->{LINE_FILTER};
        }
    }
    return $self->{LINE_FILTER};
}

sub scratch {
    my $self = shift;
    unless ($self->{SCRATCH}) {
        # This is a workspace for calculating text sizes.  I am not certain
        # that it is absolutely needed to have this in a separate PDF object,
        # but it will at least assure that the created document will be 'clean'
        my $pdf  = PDF::API2->new();
        # my @infoKeys = $scratch->infoMetaAttributes();
        my $txt  = $pdf->page()->text();
        $self->{SCRATCH} = [ $txt, $pdf ];
    }
    return wantarray ? @{$self->{SCRATCH}} : $self->{SCRATCH}[0];
}

sub add_page {
    my $self = shift;
    my $pdf  = $self->api2();
    my $pg = {
        PAGE => $pdf->page(),
    };
    push @{$self->{PAGES}}, $pg;
    $pg->{PAGENUM} = $#{$self->{PAGES}} + 1;
    return $pg;
}

sub mode {
    my $self = shift;
    if (my $nv = lc(shift || "")) {
        if ($nv =~ /word/) {
            $self->{MODE} = "Word";
        } elsif ($nv =~ /line/) {
            $self->{MODE} = "Line";
        } elsif ($nv =~ /para/) {
            $self->{MODE} = "Paragraph";
        } elsif ($nv =~ /block/) {
            $self->{MODE} = "Block";
        } else {
            $self->error("Unrecognized mode '$nv'");
        }
    }
    return $self->{MODE};
}

sub each_page { return @{shift->{PAGES}}; }

sub current_page {
    my $self = shift;
    if (my $pg = $self->{PAGES}[-1]) {
        return $pg->{PAGE};
    }
    return undef;
}

sub current_page_num { return $#{shift->{PAGES}} + 1; }

sub suffix {
    my $self = shift;
    if (defined $_[0]) {
        my $nv = $_[0];
        $nv =~ s/[\"\']//g;
        $self->{SFX} = $nv;
    }
    return $self->{SFX};
}

sub scan_resolution {
    return shift->_numeric_parameter('SCANDPI', $_[0], 1);
}

sub pdf_resolution {
    return shift->_numeric_parameter('PDFDPI', $_[0], 1);
}

*jpeg_quality = \&jpg_quality;
sub jpg_quality {
    return shift->_numeric_parameter('JPGQUAL', $_[0], 1, 100);
}

sub min_font_pt {
    return shift->_numeric_parameter('MINFTPT', $_[0]);
}

sub max_font_pt {
    return shift->_numeric_parameter('MAXFTPT', $_[0]);
}

sub _numeric_parameter {
    my $self = shift;
    my ($param, $nv, $min, $max) = @_;
    if (defined $nv) {
        if ($nv =~ /^(\d+|\d*\.\d+)$/) {
            if (defined $min && $nv < $min) {
                $self->error("Parameter '$param' must be >= $min, not '$nv'");
            } elsif (defined $max && $nv > $max) {
                $self->error("Parameter '$param' must be <= $max, not '$nv'");
            } else {
                $self->{$param} = $nv;
            }
        } else {
            $self->error("Parameter '$param' must be numeric, not '$nv'");
        }
    }
    return $self->{$param};
}

*jpeg_scale = \&jpg_scale;
sub jpg_scale {
    my $self = shift;
    return int(0.5 + 100 * $self->pdf_resolution() / $self->scan_resolution());
}

sub add_image {
    my $self = shift;
    my ($src) = @_;
    if (my $cparam = $self->clean_params()) {
        # Pre-processing of the image with ImageMagick has been requested
        my $oldSrc = $src;
        my $sfx = "jpg";
        if ($cparam =~ /(.+)\s+(png|jpg|tiff)\s*$/i) {
            # Request for a specific output format
            ($cparam, $sfx) = ($1, $2);
        }
        $src = $self->derived_filename($src, "-cleaned.$sfx", 'noSfx');
        unless (-s $src) {
            my $cmd = sprintf("convert \"%s\" %s \"%s\"",
                              $oldSrc, $cparam, $src);
            $self->log("Clean image: $cmd");
            system($cmd);
            unless (-s $src) {
                $self->error("Failed to clean input image", $cmd);
                return ();
            }
        }
    }
    my $jpgF = $self->scaled_image($src);
    my $pdf  = $self->api2;
    my $pg   = $self->add_page();
    my $page = $pg->{PAGE};
    my $gfx  = $page->gfx;
    my ($w, $h);
    if (my $img  = $pdf->image_jpeg($jpgF)) {
        my $dbg    = $self->debug_mode();
        my $scale  = 72 / $self->pdf_resolution();
        ($w, $h)   = map { $_ * $scale } ( $img->width(), $img->height() );
        $pg->{W}   = $w;
        $pg->{H}   = $h;
        $pg->{SRC} = $src;
        $pg->{JPG} = $img;
        $page->mediabox($w, $h);
        $gfx->image( $img, 0, 0, $scale );
        $self->add_grid($pg) if ($dbg);
        $self->log(sprintf("PDF page %d added: %.1fx%.1f\" <- \"%s\"",
                           $pg->{PAGENUM}, $w / 72, $h / 72, $jpgF));
    } else {
        $self->error("Failed to add JPEG file", $src);
    }
    return ($w, $h);
}

sub derived_filename {
    my $self = shift;
    my ($src, $mod, $stripSfx) = @_;
    my ($file, $dir) = ($src, "");
    $file =~ s/\.[a-z]{2,5}$//i if ($stripSfx);
    if ($file =~ /(.+\/)([^\/]+)$/) {
        ($dir, $file) = ($1, $2);
    }
    if (my $wd = $self->work_dir()) {
        # Create a new working subdirectory, unless we are already in it
        unless ($dir =~ /\Q$wd\E\/$/) {
            $dir .= "$wd/";
            mkdir($dir) unless (-d $dir);
        }
    }
    if (my $sfx = $self->suffix()) { $file .= $sfx; }
    return "$dir$file$mod";
}

sub scaled_image {
    my $self = shift;
    my $src  = shift;
    return "" unless ($src);
    if ($src =~ /[\'\"\\]/) {
        $self->error("Image names can not have quotes or backslashes");
        return "";
    }
    my $rv = $self->derived_filename($src, "-scaled.jpg", "noSfx");
    unless (-s $rv) {
        unless (-s $src) {
            $self->error("Can not scale image - no such file", $src);
            return "";
        }
        my $scale = $self->jpg_scale();
        my $qual  = $self->jpg_quality();
        my $cmd = sprintf("convert -quality %d -resize %.3f%% \"%s\" \"%s\"",
                          $qual, $scale, $src, $rv );
        $self->log(sprintf
                   ("Scaled Image by %.2f%%, Quality %d \"%s\" -> \"%s\"", 
                    $scale, $qual, $src, $rv));
        my $cd = system($cmd);
    }
    return $rv;
}

sub ocr {
    my $self = shift;
    foreach my $pg ($self->each_page()) {
        next if ($pg->{DONE}++);
        $self->process_page( $pg );
    }
}

sub process_page {
    my $self = shift;
    my $pg     = shift;
    my $xml    = $self->xml_for_image( $pg->{SRC} );
    my $parser = new XML::DOM::Parser ();
    my $outDoc;
    eval {
        $outDoc = $parser->parsefile($xml);
    };
    unless ($outDoc) {
        $self->error("Failed to read hOCR file", $xml, $@);
        return;
    }
    my ($oW, $oH);
    my $coordStuff;
    my $h = $pg->{H};
    my $w = $pg->{W};
    
    # Bogus methods in case we can not get the ocr_page object
    my $yCounter = $h;
    $pg->{xcb} = sub { return 10; };
    $pg->{ycb} = sub { return $yCounter -= 10; };

    my $mode = $self->mode();
    my @lines;
    foreach my $area ($outDoc->getElementsByTagName('div')) {
        my $cls = &get_class($area);
        my $aCoord = &bbox($area);
        if ($cls eq 'ocr_page') {
            if ($oW) {
                $self->error("Multiple hOCR DIV '$cls'");
            } elsif (!$aCoord) {
                $self->error("Failed to identify bbox for '$cls'");
            } else {
                # Capture the width and height of the full page,
                # as perceived by hOCR
                my ($oW, $oH) = ($aCoord->[2], $aCoord->[3]);
                $coordStuff = {
                    ow => $oW,
                    oh => $oH,
                    w  => $w,
                    h  => $h,
                };
                # Methods to convert hOCR coordinates to PDF coordinates
                $pg->{xcb} = sub {
                    my $ox = shift;
                    return int(0.5 + 10 * $ox * $w / $oW) / 10;
                };
                $pg->{ycb} = sub {
                    my $oy = shift;
                    return int(0.5 + 10 * ($oH - $oy) * $h / $oH) / 10;
                };
            }
            next;
        } elsif ($cls eq 'ocr_carea') {
            $self->_start_text( $pg ) if ($mode eq 'Block');
        } else {
            $self->error("Unexpected hOCR DIV '$cls'");
            next;
        }
        foreach my $para ($area->getElementsByTagName('p')) {
            $self->_start_text( $pg ) if ($mode eq 'Paragraph');
            my $via = &get_via($para);
            my %okWordClass = $via eq 'Cuneiform' ?
                ( ocr_line => 1 ) : ( ocrx_word => 1, ocr_word => 1 );
            foreach my $line ($para->getChildNodes()) {
                my $lCls = &get_class($line);
                my @words;
                if ($via eq 'Cuneiform') {
                    # There are no isolated words, just the line
                    @words = ($line);
                } elsif ($lCls eq 'ocr_line') {
                    @words = $line->getChildNodes();
                } elsif ($lCls eq 'ocr_word') {
                    # I have not seen this - a line with a single word
                    # is still nested as a line/word. But adding this
                    # block in case things change
                    @words = ($line);
                } else {
                    next;
                }
                $self->_start_text( $pg ) if ($mode eq 'Line');
                my $lineData = {
                    words => [],
                };
                push @lines, $lineData;
                foreach my $word (@words) {
                    my $wCls = &get_class($word);
                    next unless ($okWordClass{$wCls});
                    my $txt = join('',  &text_for_node($word));
                    next if ($txt =~ /^[\s\n\r]*$/);
                    push @{$lineData->{words}}, $txt;
                    $self->_start_text( $pg ) if ($mode eq 'Word');
                    push @{$pg->{words}}, [$txt, &bbox($word), $lineData];
                }
                
                $lineData->{line} = join(' ', @{$lineData->{words}})."\n";
            }
        }
    }
    
    $self->_start_text( $pg );
    $self->_write_text();
    my $bar = '-' x 30;
    $self->{TEXT} .= sprintf("\n%s %2d %s\n\n", $bar, $pg->{PAGENUM}, $bar);
    foreach my $lineDat (@lines) {
        if (my $words = $lineDat->{kept}) {
            $self->{TEXT} .= join(' ', @{$words})."\n";
        }
    }
    # Free the XML object:
    $outDoc->dispose();
}

sub add_grid {
    my $self = shift;
    my $pg   = shift;
    return unless ($pg);
    my $page = $pg->{PAGE};
    my $w    = $pg->{W};
    my $h    = $pg->{H};
    my $font = $self->api2->corefont( $self->font() );
    for (my $x = 0; $x < $w; $x += 72) {
        for (my $y = 0; $y < $h; $y += 72) {
            my $text = $page->text();
            $text->fillcolor('green');
            $text->font($font, 5);
            $text->translate($x, $y);
            $text->text("[$x,$y]");
        }
    }
}

=head1 XML Parsing Methods

These methods just wrap up some simple calls to extract the data from
hOCR nodes.

=cut

sub get_class {
    my $node = shift;
    if (!$node->can('getAttributeNode')) {
        return "";
    } elsif (my $v = $node->getAttributeNode('class')) {
        return $v->getValue();
    } else {
        return "";
    }
}

sub get_via {
    my $node = shift;
    if (!$node->can('getAttributeNode')) {
        return "";
    } elsif (my $v = $node->getAttributeNode('via')) {
        return $v->getValue();
    } else {
        return "";
    }
}

sub bbox {
    my $node = shift;
    my $rv;
    if (my $title = $node->getAttributeNode('title')) {
        $title = $title->getValue();
        if ($title =~ /bbox\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/) {
            $rv = [$1, $2, $3, $4];
        }
    }
    return $rv;
}

sub text_for_node {
    my $node = shift;
    my @texts;
    my @kids = $node->getChildNodes();
    if ($#kids == 0 && $kids[0]->getNodeName() eq '#text') {
        # A single text child - this is what we want
        push @texts, $kids[0]->getData();
    } else {
        # See if we can find grandchildren of interest
        foreach my $child ($node->getChildNodes()) {
            push @texts, &text_for_node( $child );
        }
    }
    return @texts;
}

sub _start_text {
    my $self = shift;
    my $pg   = shift;
    $self->_commit_text( $pg );
    my $tObj      = $pg->{PAGE}->text();
    $pg->{words}  = [];
    $pg->{txtObj} = $tObj;
}

sub _commit_text {
    my $self = shift;
    my $pg   = shift;
    my $tObj = $pg->{txtObj};
    return unless ($tObj);

    my @wordDat = @{$pg->{words}};
    return if ($#wordDat == -1);
    # Tally up the sizes as reported by tesseract, as well as those that
    # we get when actually rendering the text
    my ($cnum, $w, $h, $pdfW) = (0,0,0,0);
    my $string = "";

    my $fontNm   = $self->font_name();
    my $scratch  = $self->scratch();
    foreach my $wdat (@wordDat) {
        my ($chars, $box, $lineDat) = @{$wdat};
        $string .= $chars . " ";
        my ($x1, $x2) = map { $box->[$_] = &{$pg->{xcb}}($box->[$_]) } (0,2);
        my ($y1, $y2) = map { $box->[$_] = &{$pg->{ycb}}($box->[$_]) } (3,1);
        # Render the text in the scratch space to calculate actual size
        my $wid = $scratch->advancewidth($chars);
        $pdfW += $wid; 
        $cnum += length($chars);
        $w += $x2 - $x1 + 1;
        $h += $y2 - $y1 + 1;
    }
    unless ($w && $h) {
        # At least one dimension is zero
        # Should not happen...
        $self->error("[w,h] = [$w,$h] : Squashed text content", "'$string'");
        return;
    }
    unless ($pdfW) {
        # When rendered, we did not get anything
        # Should not happen
        $self->error("Text rendered to zero width");
        return;
    }
    
    # hOCR supports 'textangle' but tesseract does not appear to use it
    # So we will see if the concatenated strings are 'wide' or 'high'
    # Tall, thin boxes will be presumed vertical text
    # While we are doing that, also calculate the font scaling factor

    my $ratio     = $h / $w;
    my $fontScale = 1;
    my $angle     = 0;
    if ($ratio > 1 && $cnum > 3) {
        # Ok, this looks like it is vertical
        # I am not sure how to detect text that is rotated -90
        $angle = 90;
        # We need to scale off of the height, rather than the width
         $fontScale = $h / $pdfW;
     } else {
         # We will be using the width to calculate the appropriate font
         $fontScale = $w / $pdfW;
    }
    my $useFontSz = int(0.5 + 100 * $tryFnt * $fontScale) / 100;
    if (my $mft = $self->min_font_pt()) {
        # Really small text is generally noise
        if ($useFontSz < $mft) {
            $self->{FILTERED}{"Word font < ${mft}pt"}++;
            return;
        }
    }
    if (my $mft = $self->max_font_pt()) {
        # Big text is more likely to be real, but is also often artifacts
        if ($useFontSz > $mft) {
            $self->{FILTERED}{"Word font > ${mft}pt"}++;
            return;
        }
    }
    $self->{SEENFONT}{int($useFontSz)} += $cnum;
    push @{$self->{PENDING}}, [$tObj, $useFontSz, \@wordDat, $angle];
    # &metaSearch( $string );
    
}

sub _write_text {
    my $self = shift;
    my $pdf  = $self->api2();
    my $font = $pdf->corefont($self->font_name());
    my $dbg  = $self->debug_mode();
    my $eg   = $self->extended_graphics();

    if (0) {
        # Trying to figure out a way to automatically find unusually small
        # or large characters...
        my ($num, $sum, $sumsum) = (0, 0, 0);
        my $seen = $self->{SEENFONT};
        while (my ($sz, $chars) = each %{$seen}) {
            $num    += $chars;
            $sum    += $chars * $sz;
            $sumsum += $chars * $sz * $sz;
        }
        return unless ($num);

        my $mean = $sum / $num;
        my $stdv = sqrt(($sumsum / $num) - ($mean * $mean));
        # $self->msg(sprintf("Font %.2f +/- %.2f pt", $mean, $stdv));
        # die $self->branch($seen);
        
        my $minSz = $mean / 3;
        my $maxSz = $mean * 3;
        #$self->msg("[INFO]", sprintf
        #           ("%d charachters, Avg Font: %.2f +/- %.2f [%.2f-%.2f]",
        #            $num, $mean, $stdv, $minSz, $maxSz),
        #           map { sprintf(" %4d : %5d", $_, $seen->{$_}) }
        #           sort {$a <=> $b } keys %{$seen});
    }

    my $lfCB     = $self->line_filter();
    foreach my $tdat (@{$self->{PENDING}}) {
        my ($tObj, $useFontSz, $words, $angle) = @{$tdat};
        #$self->msg("[FONT]", sprintf("%.2fpt", $useFontSz),
        #           join(' ', map { $_->[0] } @{$words})) if ($useFontSz > 12);

        $tObj->font($font, $useFontSz);
        
        # Now we can place all the words within the text box
        if ($dbg) {
            # Glaring red text for debugging
            $tObj->fillcolor('red');
        } else {

            # Set the text to be transparent. It will 'float' over the
            # image, but can be selected to copy (and will become
            # visible when selected)

            $tObj->egstate($eg);
        }
        foreach my $wdat (@{$words}) {
            # $tObj->translate( $wdat->[1][0], $wdat->[1][3] );
            my ($txt, $box, $lineDat) = @{$wdat};
            if ($lfCB) {

                # Check user-supplied callback to see if we should reject
                # the whole line. This functionality was added when I
                # found that fine dashed lines in my bank report were
                # becomming stretches of gibberish that could be
                # identified because they were heavy with lowercase 'w'
                # and 'm'.
                unless (defined $lineDat->{filter}) {
                    if (my $reas = $lineDat->{filter} = 
                        &{$lfCB}($self, $lineDat)) {
                        $self->{FILTERED}{$reas}++;
                        # $self->msg("[-]", $reas, $lineDat->{line});
                   }
                }
                if (my $reas = $lineDat->{filter}) {
                    next;
                }
            }
            push @{$lineDat->{kept}}, $txt;
            my ($x, $y) = ($box->[0], $box->[3]);
            if ($angle) {
                # Pivot is about lower left corner
                # We need to shift the x coordinate by half the height
                $x += ($box->[2] - $x) / 2;
            }
            # I could only get rotation to work if I used transform()
            # and rotated and transformed in one operation:
            $tObj->transform( -rotate    => $angle,
                              -translate => [$x, $y] );
            $tObj->text($txt . " ");
        }
    }
    my @filtReas = map { sprintf("  %4d : %s", $self->{FILTERED}{$_}, $_) }
    sort keys %{$self->{FILTERED} || {}};
    $self->log("User filters applied:", @filtReas) unless ($#filtReas == -1);
    delete $self->{PENDING};
    delete $self->{FILTERED};
    delete $self->{SEENFONT};
}

sub xml_for_image {
    my $self = shift;
    my $src  = shift;
    my $xml  = $self->derived_filename($src, ".xml");
    return $xml if (-s $xml);
    my $hocr = $self->hocr_for_image( $src );
    return "" unless ($hocr);
    if ($hocr =~ /\.hocr$/) {
        # Newer HOCR files appear to be ok... ?
        return $hocr;
    } elsif ($hocr =~ /\.c.html$/) {
        # Cuneiform needs some basic cleanup
        return $self->_clean_cuneiform_hocr( $hocr, $xml );
    } else {
        return $self->_clean_tesseract_hocr( $hocr, $xml );
    }
}

sub _clean_cuneiform_hocr {
    my $self = shift;
    my ( $hocr, $xml ) = @_;

    # Cuneiform included unclosed meta tags that caused XML parsing problems
    # It also includes character-by-character positional data that do not
    # interst me.
    unless (open(HTML, "<$hocr")) {
        $self->error("Failed to open HTML file for cleaning", $!, $hocr);
        return "";
    }
    unless (open(XML, ">$xml")) {
        $self->error("Failed to create XML file", $!, $xml);
        close HTML;
        return "";
    }
    while (<HTML>) {
        if (/^(\s*<meta.+[^\/\s])\s*>\s*$/) {
            # Close the meta tag
            print XML "$1 />\n";
        } elsif (/^(<p[^>]*>)?(<span.+class='ocr_line'.+)/) {
            # cuneiform appears to structure all the OCR'ed data in lines
            # 
            my ($para, $line) = ($1, $2);
            if ($para) {
                $para =~ s/\>$//;
                # Quote attributes
                $para =~ s/=(\S+)/='$1'/g;
                # Try to normalize the structure to be a bit more like
                # Tesseract, to make later parsing easier
                print XML "<div class='ocr_carea'>";
                # Also embed a 'via' flag to guide parsing mode
                print XML "$para via='Cuneiform' class='ocr_par'>\n"
            }
            # I do not care about the per-character bound boxes:
            $line =~ s/<span class='ocr_cinfo'.+?<\/span>//g;
            # Close break tags:
            $line =~ s/<br>/<br \/>/g;
            $line =~ s/[\n\r]+$//;
            print XML "  $line\n";
        } elsif (/^\s*<\/p>\s*$/) {
            print XML "</p></div>\n";
        } else {
            print XML $_;
        }
    }
    close XML;
    close HTML;
    return $xml;
}
    
sub _clean_tesseract_hocr {
    my $self = shift;
    my ( $hocr, $xml ) = @_;

    # Older tesseract hOCR includes non-ASCII encoded characters.
    # These break DOM parsing, at least for my libraries
    unless (open(HTML, "<$hocr")) {
        $self->error("Failed to open HTML file for cleaning", $!, $hocr);
        return "";
    }
    unless (open(XML, ">$xml")) {
        $self->error("Failed to create XML file", $!, $xml);
        close HTML;
        return "";
    }
    my $ind   = -1;
    my $prior = 0;
    my $swapTok    = 'SwAp*ToKeN';
    my $swapFmt    = $swapTok.'[%d]';
    while (<HTML>) {
        # Start by getting rid of zero width characters
        # Most of these will likely not be generated, but
        # this will identify \n and \r as well
        # $debugXML = 1 if (/word_83\b/);
        # $args->msg("[<]", "||$_||") if ($debugXML);
        tr/\x00-\x1F//d;
        # Now identify non-ascii characters
        my @found;
        while (/([^\x20-\x7E])/) {
            # There are non-ASCII characters in this block
            my $in  = $1;
            push @found, sprintf("&#x%X;", ord($in));
            my $out = sprintf($swapFmt, $#found);
            s/\Q$in\E/$out/g;
        }
        # It seems that occasionally Tesseract does not
        # escape all the "naughty" characters, like <>&

        # This causes XML parsing to crash. We need to
        # remove properly escaped character entities, as
        # well as whole XML tags

        while (/(&#\d+;|&quot;|<[^>\*]+?>)/) {
            my $in  = $1;
            push @found, $in;
            my $out = sprintf($swapFmt, $#found);
            s/\Q$in\E/$out/g;
        }
        # $args->msg("[*]", "||$_||") if ($debugXML);
        # ... And then we can remove the straggler characters:
        while (/([&<>])/) {
            my $in  = $1;
            push @found, sprintf("&#x%X;", ord($in));
            my $out = sprintf($swapFmt, $#found);
            s/\Q$in\E/$out/g;
        }
        #if ($debugXML) {
        #    $args->msg("[-]", "||".join(",", @found)."||");
        #    my $residual = $_;
        #    $residual =~ s/$swapTok\[\d+\]//g;
        #    $args->msg("[+]", "||$residual||");
        #}
        # Now we can put back in all the character entities:
        for my $f (0..$#found) {
            my $in = sprintf($swapFmt, $f );
            my $out = $found[$f];
            s/\Q$in\E/$out/g;
        }
        
        # tr/\040-\176/ /cd;
        # We could stop here - the document is now a single
        # line of (hopefully) well-formed XML

        # But, while we are here, clean up the XML a bit
        # I did this primarily to help myself understand the
        # XML structure of the output
        s/[\r\n]+$//;
        my @bits = split(/</, $_);
        # $args->msg("[>]", "||$_||", map { "{$_}" } @bits) if ($debugXML);
        for my $bi (0..$#bits) {
            my $lt   = $bi ? "<" : "";
            my $bit  = $bits[$bi];
            if ($bit eq '') {
                print XML $lt;
                next;
            }
            my $step = ($bit =~ /^\//) ? -1 : 1;
            $ind += $step;
            if ($prior) {
                print XML "\n".(" "x$ind)."$lt$bit";
            } else {
                print XML "$lt$bit";
            }
            $prior = $bit =~ />$/ ? $step : 0;
        }
        # $debugXML = 0 if (/word_85\b/);

    }
    close XML;
    close HTML;
    return $xml;
}

sub hocr_for_image {
    # https://en.wikipedia.org/wiki/HOCR
    my $self = shift;
    my $src    = shift;
    my $base   = $self->derived_filename($src, "-HOCR", 'noSfx');
    my $engine = $self->engine();
    my $cmd;
    my @targets;
    if ($engine eq 'Cuneiform') {
        @targets = ("$base.c.html");
        $cmd = sprintf("cuneiform -f hocr -i \"%s\" -o \"%s\"",
                       $src, $targets[0]);
    } else {
        # Naming change - older versions use .html
        @targets = ("$base.hocr", "$base.html");
        $cmd = sprintf("tesseract \"%s\" \"%s\" hocr",
                       $src, $base);
    }
    foreach my $out (@targets) {
        return $out if (-s $out);
    }

    # If we are here then we need to try to generate the file
    $self->log("OCR Command: $cmd");
    system($cmd);
    foreach my $out (@targets) {
        return $out if (-s $out);
    }
    $self->error("Could not find expected hOCR output file", @targets);
    return "";
}

sub error {
    my $self = shift;
    $self->msg("[!!]", @_);
    $self->log(map { "  ERR: $_" } @_);
}

sub log {
    my $self = shift;
    foreach my $nv (@_) {
        push @{$self->{LOG}}, $nv if (defined $nv);
    }
    return $self->{LOG};
}

sub log_text {
    my $self = shift;
    my $log  = $self->log();
    return join("\n", @{$log})."\n";
}

1;
