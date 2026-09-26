/// `clipForComplaint`: a peer-supplied identifier cut to a length a complaint
/// line can carry.
///
/// §5's rule is that a complaint carries an error's type and never its
/// message, because gateway-supplied text is unbounded and the line reaches a
/// panel. An identifier — the handle or key the complaint is *about* — has to
/// be named or the line cannot be acted on, but it came off the same wire, so
/// it is named and cut. These arms pin the cut and the two things it must not
/// do: shorten a tag name the plant actually uses, or refuse a non-string.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  test('a plant tag name survives whole', () {
    const tag = 'ST101.CN01.MOT01.p_stat_RunMode';
    expect(clipForComplaint(tag), tag);
    expect(tag.length, lessThan(maxComplaintIdentifierLength),
        reason: 'the bound must clear every AREAnn.DEVnn.SUBnn.member name');
  });

  test('a megabyte of handle key becomes sixty-four characters and a mark',
      () {
    final huge = 'k' * (1024 * 1024);
    final clipped = clipForComplaint(huge);
    expect(clipped.length, maxComplaintIdentifierLength + 1);
    expect(clipped, endsWith('…'),
        reason: 'a silent cut reads as the whole identifier');
    expect(clipped.substring(0, maxComplaintIdentifierLength),
        'k' * maxComplaintIdentifierLength);
  });

  test('exactly at the bound is not cut', () {
    final exact = 'x' * maxComplaintIdentifierLength;
    expect(clipForComplaint(exact), exact);
  });

  test('a non-string is described rather than refused a description', () {
    expect(clipForComplaint(7), '7');
    expect(clipForComplaint(null), 'null');
    expect(clipForComplaint(<Object?>[1, 2]), '[1, 2]');
  });
}
