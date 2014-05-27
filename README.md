TesseractPDF
============

TesseractPDF is designed to produce searchable PDF documents from
scanned images. It contains no OCR code itself, but instead uses
system calls to [tesseract](https://code.google.com/p/tesseract-ocr/)
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

PDF manipulations are done using PDF::API2. hOCR parsing uses
XML::DOM. Also requires BMS::Utilities, which at the moment can be
found at [another
project](https://github.com/VCF/MapLoc/blob/master/BMS/Utilities.pm).

Cuneiform
---------

The module also has support for [Cuneiform](http://en.openocr.org/). A
cursory comparison of Tesseract with Cuneiform indicates that they
have different false negative and false positive profiles; text missed
or mangled by one engine will be correctly parsed by the other.

See Also
--------

[OCRFeeder](http://www.live.gnome.org/OCRFeeder) is a GUI helper that
allows a choice of Tesseract, Cuneiform and GOCR. It has additional
features such as deskew and what appears to be more sophisticated
recognition of text and graphics blocks prior to OCR. It may be
available from your distribution's repository.

