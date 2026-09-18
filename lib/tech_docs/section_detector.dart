/// PDF section detection algorithm.
///
/// Classifies text fragments by bounds-height ratio into a hierarchical
/// section tree (chapters > sections > subsections).
library;

import 'package:tfc_mcp_server/tfc_mcp_server_data.dart' show ParsedSection;

export 'package:tfc_mcp_server/tfc_mcp_server_data.dart' show ParsedSection;

/// Lightweight input model for section detection.
///
/// Represents a text fragment extracted from a PDF with its measured height
/// (proxy for font size) and page number.
class SizedFragment {
  final String text;
  final double height;
  final int pageNumber;

  const SizedFragment({
    required this.text,
    required this.height,
    required this.pageNumber,
  });
}

/// Internal intermediate representation of a flat section before tree building.
class _RawSection {
  final String title;
  final int level; // 0=chapter, 1=section, 2=subsection
  final int pageStart;
  final StringBuffer contentBuffer = StringBuffer();
  int lastPageSeen;

  _RawSection({
    required this.title,
    required this.level,
    required this.pageStart,
  }) : lastPageSeen = pageStart;

  void appendContent(String text, int pageNumber) {
    if (contentBuffer.isNotEmpty) {
      contentBuffer.write('\n');
    }
    contentBuffer.write(text);
    if (pageNumber > lastPageSeen) {
      lastPageSeen = pageNumber;
    }
  }

  String get content => contentBuffer.toString();
}

/// Detects and classifies PDF text fragments into hierarchical sections.
///
/// Operates on [SizedFragment] input objects (text, height, pageNumber).
/// The actual pdfrx extraction happens elsewhere (Plan 04).
class SectionDetector {
  /// Ratio threshold for chapter headings (default 2.0x median height).
  final double chapterThreshold;

  /// Ratio threshold for section headings (default 1.4x median height).
  final double sectionThreshold;

  /// Ratio threshold for subsection headings (default 1.15x median height).
  final double subsectionThreshold;

  /// Maximum word count for a heading. Longer text at heading height is
  /// treated as bold body text to prevent false positives.
  final int maxHeadingWords;

  const SectionDetector({
    this.chapterThreshold = 2.0,
    this.sectionThreshold = 1.4,
    this.subsectionThreshold = 1.15,
    this.maxHeadingWords = 12,
  });

  /// Detect sections from a list of sized fragments.
  ///
  /// Returns a hierarchical list of [ParsedSection] objects where chapters
  /// contain sections which contain subsections.
  ///
  /// Algorithm:
  /// 1. Filter out empty text fragments
  /// 2. Calculate median height from all fragments
  /// 3. Classify each fragment by height/median ratio and word count
  /// 4. Build flat list of raw sections, accumulating body text
  /// 5. Build hierarchical tree (chapters > sections > subsections)
  /// 6. Assign sortOrder and compute page ranges
  List<ParsedSection> detectSections(List<SizedFragment> fragments) {
    // Step 1: Filter out empty/whitespace-only fragments.
    final filtered = fragments
        .where((f) => f.text.trim().isNotEmpty)
        .toList(growable: false);

    if (filtered.isEmpty) return const [];

    // Step 2: Calculate median height.
    final medianHeight = _calculateMedianHeight(filtered);

    // Step 3+4: Classify fragments and build flat section list.
    final (rawSections, hasHeadings) =
        _buildRawSections(filtered, medianHeight);

    if (!hasHeadings) {
      // All fragments are body text with no headings -- wrap in single section.
      return [_buildDocumentContentSection(filtered)];
    }

    // Determine overall last page number.
    final lastPage = filtered.map((f) => f.pageNumber).reduce(
        (a, b) => a > b ? a : b);

    // Step 5: Build hierarchical tree.
    // Step 6: Assign sortOrder and compute page ranges.
    return _buildHierarchy(rawSections, lastPage);
  }

  /// Compute the median height from a list of fragments.
  double _calculateMedianHeight(List<SizedFragment> fragments) {
    final heights = fragments.map((f) => f.height).toList()..sort();
    final mid = heights.length ~/ 2;
    if (heights.length.isOdd) {
      return heights[mid];
    }
    return (heights[mid - 1] + heights[mid]) / 2.0;
  }

  /// Classify a fragment's heading level based on height ratio to median.
  ///
  /// Returns -1 for body text, 0 for chapter, 1 for section, 2 for subsection.
  int _classifyLevel(SizedFragment fragment, double medianHeight) {
    final ratio = fragment.height / medianHeight;
    final wordCount = fragment.text.trim().split(RegExp(r'\s+')).length;

    // Long text at heading height is bold body, not a heading.
    if (wordCount > maxHeadingWords) return -1;

    if (ratio >= chapterThreshold) return 0;
    if (ratio >= sectionThreshold) return 1;
    if (ratio >= subsectionThreshold) return 2;
    return -1; // body text
  }

  /// Build a flat list of raw sections from classified fragments.
  ///
  /// Body text is accumulated into the nearest preceding heading's section.
  /// Body text before any heading creates a preamble section.
  ///
  /// Returns a tuple of (sections, hasHeadings) where hasHeadings indicates
  /// whether any actual headings were found (as opposed to only body text).
  (List<_RawSection>, bool) _buildRawSections(
      List<SizedFragment> fragments, double medianHeight) {
    final rawSections = <_RawSection>[];
    _RawSection? preamble;
    var hasHeadings = false;

    for (final fragment in fragments) {
      final level = _classifyLevel(fragment, medianHeight);

      if (level >= 0) {
        // This is a heading -- start a new section.
        hasHeadings = true;
        rawSections.add(_RawSection(
          title: fragment.text.trim(),
          level: level,
          pageStart: fragment.pageNumber,
        ));
      } else {
        // Body text -- accumulate into the most recent section.
        if (rawSections.isNotEmpty) {
          rawSections.last.appendContent(
              fragment.text.trim(), fragment.pageNumber);
        } else {
          // Body text before any heading -- create preamble.
          preamble ??= _RawSection(
            title: 'Preamble',
            level: 0,
            pageStart: fragment.pageNumber,
          );
          preamble.appendContent(fragment.text.trim(), fragment.pageNumber);
        }
      }
    }

    // Insert preamble at the beginning if it exists.
    if (preamble != null) {
      rawSections.insert(0, preamble);
    }

    return (rawSections, hasHeadings);
  }

  /// Build a fallback section for documents with no detected headings.
  ParsedSection _buildDocumentContentSection(List<SizedFragment> fragments) {
    final content = fragments.map((f) => f.text.trim()).join('\n');
    final firstPage = fragments.first.pageNumber;
    final lastPage = fragments.map((f) => f.pageNumber).reduce(
        (a, b) => a > b ? a : b);

    return ParsedSection(
      title: 'Document Content',
      content: content,
      pageStart: firstPage,
      pageEnd: lastPage,
      level: 0,
      sortOrder: 0,
    );
  }

  /// Build the hierarchical tree from a flat list of raw sections.
  ///
  /// Chapters (level 0) are top-level. Sections (level 1) are nested under
  /// the most recent chapter. Subsections (level 2) are nested under the
  /// most recent section.
  List<ParsedSection> _buildHierarchy(
      List<_RawSection> rawSections, int lastPage) {
    // First, compute pageEnd for each raw section.
    // pageEnd = the page just before the next section starts, or lastPage.
    _computePageEnds(rawSections, lastPage);

    // Group into hierarchy.
    final topLevel = <_RawSection>[];
    final sectionChildren =
        <_RawSection, List<_RawSection>>{}; // chapter -> sections
    final subsectionChildren =
        <_RawSection, List<_RawSection>>{}; // section -> subsections

    _RawSection? currentChapter;
    _RawSection? currentSection;

    for (final raw in rawSections) {
      switch (raw.level) {
        case 0:
          topLevel.add(raw);
          sectionChildren[raw] = [];
          currentChapter = raw;
          currentSection = null;
        case 1:
          if (currentChapter != null) {
            sectionChildren[currentChapter]!.add(raw);
            subsectionChildren[raw] = [];
            currentSection = raw;
          } else {
            // Section without a preceding chapter -- promote to top level.
            topLevel.add(raw);
            sectionChildren[raw] = [];
            subsectionChildren[raw] = [];
            currentSection = raw;
          }
        case 2:
          if (currentSection != null) {
            subsectionChildren[currentSection]!.add(raw);
          } else if (currentChapter != null) {
            // Subsection without a preceding section -- attach to chapter.
            sectionChildren[currentChapter]!.add(raw);
          } else {
            // Subsection without any parent -- promote to top level.
            topLevel.add(raw);
          }
      }
    }

    // Convert to ParsedSection tree.
    return _convertToSections(
        topLevel, sectionChildren, subsectionChildren, lastPage);
  }

  /// Compute pageEnd for each raw section in the flat list.
  void _computePageEnds(List<_RawSection> rawSections, int lastPage) {
    for (var i = 0; i < rawSections.length; i++) {
      final raw = rawSections[i];
      if (i < rawSections.length - 1) {
        final nextStart = rawSections[i + 1].pageStart;
        // pageEnd is the max of the last body page seen and (next start - 1).
        raw.lastPageSeen = _max(raw.lastPageSeen, nextStart - 1);
      } else {
        // Last section extends to the last page of the document.
        raw.lastPageSeen = _max(raw.lastPageSeen, lastPage);
      }
    }
  }

  /// Convert the grouped raw sections into ParsedSection objects.
  List<ParsedSection> _convertToSections(
    List<_RawSection> topLevel,
    Map<_RawSection, List<_RawSection>> sectionChildren,
    Map<_RawSection, List<_RawSection>> subsectionChildren,
    int lastPage,
  ) {
    final result = <ParsedSection>[];

    for (var i = 0; i < topLevel.length; i++) {
      final chapter = topLevel[i];
      final sections = sectionChildren[chapter] ?? [];

      final childSections = <ParsedSection>[];
      for (var j = 0; j < sections.length; j++) {
        final section = sections[j];
        final subsections = subsectionChildren[section] ?? [];

        final childSubsections = <ParsedSection>[];
        for (var k = 0; k < subsections.length; k++) {
          childSubsections.add(ParsedSection(
            title: subsections[k].title,
            content: subsections[k].content,
            pageStart: subsections[k].pageStart,
            pageEnd: subsections[k].lastPageSeen,
            level: 2,
            sortOrder: k,
          ));
        }

        childSections.add(ParsedSection(
          title: section.title,
          content: section.content,
          pageStart: section.pageStart,
          pageEnd: section.lastPageSeen,
          level: 1,
          sortOrder: j,
          children: childSubsections,
        ));
      }

      result.add(ParsedSection(
        title: chapter.title,
        content: chapter.content,
        pageStart: chapter.pageStart,
        pageEnd: chapter.lastPageSeen,
        level: chapter.level,
        sortOrder: i,
        children: childSections,
      ));
    }

    return result;
  }

  int _max(int a, int b) => a > b ? a : b;
}
