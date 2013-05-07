package Spreadsheet::Template::Generator::Parser::XLSX;
use Moose;

use POSIX;
use Spreadsheet::XLSX;
use XML::Entities;
use XML::Twig;

with 'Spreadsheet::Template::Generator::Parser::Excel';

sub _build_excel {
    my $self = shift;
    my $excel = Spreadsheet::XLSX->new($self->filename);
    $self->_fixup_excel($excel);
    return $excel;
}

# XXX Spreadsheet::XLSX doesn't extract this information currently
sub _fixup_excel {
    my $self = shift;
    my ($excel) = @_;

    my $book_xml = $self->_parse_xml("xl/workbook.xml");
    $self->_parse_selected_sheet($excel, $book_xml->root);

    my $styles_xml = $self->_parse_xml("xl/styles.xml");
    $self->_parse_styles($excel, $styles_xml->root);

    for my $sheet ($excel->worksheets) {
        my $sheet_xml = $self->_parse_xml("xl/$sheet->{path}");

        $self->_parse_cell_sizes($sheet, $sheet_xml->root);
        $self->_parse_formulas($sheet, $sheet_xml->root);
        $self->_parse_sheet_selection($sheet, $sheet_xml->root);
    }
}

sub _parse_selected_sheet {
    my $self = shift;
    my ($excel, $root) = @_;

    my ($node) = $root->find_nodes('//workbookView');
    my $selected = $node->att('activeTab');

    $excel->{SelectedSheet} = defined($selected) ? 0+$selected : 0;
}

sub _parse_styles {
    my $self = shift;
    my ($excel, $root) = @_;

    my %halign = (
        none   => 0,
        left   => 1,
        center => 2,
        right  => 3,
        # XXX ...
    );

    my %valign = (
        top    => 0,
        center => 1,
        bottom => 2,
        # XXX ...
    );

    my $rels_xml = $self->_parse_xml("xl/_rels/workbook.xml.rels");
    my ($theme_file) = map {
        $_->att('Target')
    } grep {
        $_->att('Type') =~ m{/theme$};
    } $rels_xml->root->find_nodes('//Relationships/Relationship');

    my $theme_xml = $self->_parse_xml("xl/$theme_file");

    my @colors = map {
        $_->name eq 'a:sysClr' ? $_->att('lastClr') : $_->att('val')
    } $theme_xml->root->find_nodes('//a:clrScheme/*/*');

    # this shouldn't be necessary, but the documentation is wrong here
    # see http://stackoverflow.com/questions/2760976/theme-confusion-in-spreadsheetml
    ($colors[0], $colors[1]) = ($colors[1], $colors[0]);
    ($colors[2], $colors[3]) = ($colors[3], $colors[2]);

    my @fills = map {
        my $fgcolor_node = $_->first_child('fgColor');
        my $fgcolor = 64; # XXX
        if ($fgcolor_node) {
            $fgcolor = '#' . $colors[$fgcolor_node->att('theme')]
                if defined $fgcolor_node->att('theme');
            $fgcolor = $fgcolor_node->att('indexed')
                if defined $fgcolor_node->att('indexed');
        }
        [
            0, # XXX
            $fgcolor,
            0, # XXX
        ]
    } $root->find_nodes('//fills/fill/patternFill');

    $excel->{FormatStr} = {
        0 => 'GENERAL',
        map {
            $_->att('numFmtId') => $_->att('formatCode')
        } $root->find_nodes('//numFmts/numFmt')
    };

    $excel->{Font} = [
        map {
            my $iHeight = 0+$_->first_child('sz')->att('val');
            my $color_node = $_->first_child('color');
            my $color = defined($color_node->att('theme'))
                ? $colors[$color_node->att('theme')]
                : substr($color_node->att('rgb'), 2, 6);
            my $sFntName = $_->first_child('name')->att('val');

            Spreadsheet::ParseExcel::Font->new(
                Height         => $iHeight,
                # Attr           => $iAttr,
                Color          => "#$color",
                # Super          => $iSuper,
                # UnderlineStyle => $iUnderline,
                Name           => $sFntName,

                # Bold      => $bBold,
                # Italic    => $bItalic,
                # Underline => $bUnderline,
                # Strikeout => $bStrikeout,
            )
        } $root->find_nodes('//fonts/font')
    ];

    # XXX what do applyFont, applyFill, and applyAlignment mean?
    $excel->{Format} = [
        map {
            my $alignment = $_->first_child('alignment');

            my $iFnt = $_->att('fontId');
            my $iIdx = $_->att('numFmtId');
            my $iAlH = $alignment
                ? $halign{$alignment->att('horizontal') || 'none'}
                : 0;
            my $iWrap = $alignment
                ? $alignment->att('wrapText')
                : 0;
            my $iAlV = $alignment
                ? $valign{$alignment->att('vertical') || 'bottom'}
                : 2;

            Spreadsheet::ParseExcel::Format->new(
                IgnoreFont      => !$_->att('applyFont'),
                IgnoreFill      => !$_->att('applyFill'),
                IgnoreBorder    => !$_->att('applyBorder'),
                IgnoreAlignment => !$_->att('applyAlignment'),

                FontNo => $iFnt,
                Font   => $excel->{Font}[$iFnt],
                FmtIdx => $iIdx,

                # Lock     => $iLock,
                # Hidden   => $iHidden,
                # Style    => $iStyle,
                # Key123   => $i123,
                AlignH   => $iAlH,
                Wrap     => $iWrap,
                AlignV   => $iAlV,
                # JustLast => $iJustL,
                # Rotate   => $iRotate,

                # Indent  => $iInd,
                # Shrink  => $iShrink,
                # Merge   => $iMerge,
                # ReadDir => $iReadDir,

                # BdrStyle => [ $iBdrSL, $iBdrSR,  $iBdrST, $iBdrSB ],
                # BdrColor => [ $iBdrCL, $iBdrCR,  $iBdrCT, $iBdrCB ],
                # BdrDiag  => [ $iBdrD,  $iBdrSD,  $iBdrCD ],
                Fill     => $fills[$_->att('fillId')],
            )
        } $root->find_nodes('//cellXfs/xf')
    ];

    for my $sheet ($excel->worksheets) {
        my $sheet_xml = $self->_parse_xml("xl/$sheet->{path}");

        $self->_parse_sheet_formats($excel, $sheet, $sheet_xml->root);
    }
}

sub _parse_cell_sizes {
    my $self = shift;
    my ($sheet, $root) = @_;

    my @column_widths;
    my @row_heights;

    my ($format) = $root->find_nodes('//sheetFormatPr');
    my $default_row_height = $format->att('defaultRowHeight') || 15;
    my $default_column_width = $format->att('baseColWidth') || 10;

    for my $col ($root->find_nodes('//col')) {
        $column_widths[$col->att('min') - 1] = $col->att('width');
    }

    for my $row ($root->find_nodes('//row')) {
        $row_heights[$row->att('r') - 1] = $row->att('ht');
    }

    $sheet->{DefRowHeight} = 0+$default_row_height;
    $sheet->{DefColWidth} = 0+$default_column_width;
    $sheet->{RowHeight} = [
        map { defined $_ ? 0+$_ : 0+$default_row_height } @row_heights
    ];
    $sheet->{ColWidth} = [
        map { defined $_ ? 0+$_ : 0+$default_column_width } @column_widths
    ];
}

sub _parse_formulas {
    my $self = shift;
    my ($sheet, $root) = @_;

    for my $formula ($root->find_nodes('//f')) {
        my $cell_id = $formula->parent->att('r');
        my ($row, $col) = $self->_cell_to_row_col($cell_id);
        my $cell = $sheet->get_cell($row, $col);
        $cell->{Formula} = "=" . $formula->text;
    }
}

sub _parse_sheet_selection {
    my $self = shift;
    my ($sheet, $root) = @_;

    my ($selection) = $root->find_nodes('//selection');
    my $cell = $selection->att('activeCell');

    $sheet->{Selection} = [ $self->_cell_to_row_col($cell) ];
}

sub _parse_sheet_formats {
    my $self = shift;
    my ($excel, $sheet, $root) = @_;

    for my $cell ($root->find_nodes('//c')) {
        my $idx = $cell->att('s');
        next unless defined $idx;
        my $cell_id = $cell->att('r');
        my ($row, $col) = $self->_cell_to_row_col($cell_id);
        $sheet->get_cell($row, $col)->{Format} = $excel->{Format}[$idx];
    }
}

sub _parse_xml {
    my $self = shift;
    my ($subfile) = @_;

    my $filename = $self->filename;

    my $zip = Archive::Zip->new;
    die "Can't open $filename as zip file"
        unless $zip->read($filename) == Archive::Zip::AZ_OK;

    my $contents = $zip->memberNamed($subfile)->contents;
    next unless $contents;

    my $xml = XML::Twig->new;
    $xml->parse($contents);

    return $xml;
}

sub _cell_to_row_col {
    my $self = shift;
    my ($cell) = @_;

    my ($col, $row) = $cell =~ /([A-Z]+)([0-9]+)/;
    $col =~ tr/A-Z/0-9A-P/;
    $col = POSIX::strtol($col, 26);
    $row = $row - 1;

    return ($row, $col);
}

# XXX this stuff all feels like working around bugs in Spreadsheet::XLSX -
# maybe look into that at some point
sub _filter_cell_contents {
    my $self = shift;
    my ($contents, $type) = @_;

    $contents = XML::Entities::decode('all', $contents);

    if ($type eq 'number') {
        $contents = 0+$contents;
    }

    return $contents;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
