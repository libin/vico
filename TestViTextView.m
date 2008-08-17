#import "TestViTextView.h"

/* Given an input text and location, apply the command keys and check
 * that the result is what we expect.
 */
#define TEST(inText, inLocation, commandKeys, outText, outLocation)          \
	[vi setString:inText];                                               \
	[vi setSelectedRange:NSMakeRange(inLocation, 0)];                    \
	[vi input:commandKeys];                                              \
	STAssertEqualObjects([[vi textStorage] string], outText, nil);       \
	STAssertEquals([vi selectedRange].location, (NSUInteger)outLocation, nil);

/* motion commands don't alter the text */
#define MOVE(inText, inLocation, commandKeys, outLocation) \
	TEST(inText, inLocation, commandKeys, inText, outLocation)

@implementation TestViTextView

- (void)setUp
{
	vi = [[ViTextView alloc] initWithFrame:NSMakeRect(0, 0, 320, 200)];
	[vi initEditor];
}

- (void)test001_AllocateTextView		{ STAssertNotNil(vi, nil); }

#if 0
// FIXME: input keys passed through to the super NSTextView doesn't work yet
- (void)test010_InsertText			{ TEST(@"abc def", 3, @"i qwerty", @"abc qwerty def", 9); }
- (void)test011_InsertMovesBackward		{ TEST(@"abc def", 3, @"i\x1b", @"abc def", 2); }
#endif

- (void)test020_DeleteForward			{ TEST(@"abcdef", 0, @"x", @"bcdef", 0); }
- (void)test021_DeleteForwardAtEol		{ TEST(@"abc\ndef", 2, @"x", @"ab\ndef", 1); }
- (void)test022_DeleteForewardWithCount		{ TEST(@"abcdef", 1, @"3x", @"aef", 1); }
- (void)test023_DeleteForwardWithLargeCount	{ TEST(@"abcdef\nghi", 4, @"33x", @"abcd\nghi", 4); }

- (void)test030_DeleteBackward			{ TEST(@"abcdef", 3, @"X", @"abdef", 2); }
- (void)test031_DeleteBackwardAtBol		{ TEST(@"abcdef", 0, @"X", @"abcdef", 0); }
- (void)test032_DeleteBackwardWithCount		{ TEST(@"abcdef", 5, @"4X", @"af", 1); }
- (void)test033_DeleteBackwordWithLargeCount	{ TEST(@"abcdef", 2, @"7X", @"cdef", 0); }

- (void)test040_WordForward			{ MOVE(@"abc def", 0, @"w", 4); }
- (void)test041_WordForwardFromBlanks		{ MOVE(@"   abc def", 0, @"w", 3); }
- (void)test042_WordForwardToNonword		{ MOVE(@"abc() def", 0, @"w", 3); }
- (void)test043_WordForwardFromNonword		{ MOVE(@"abc() def", 3, @"w", 6); }
- (void)test044_WordForwardAcrossLines		{ MOVE(@"abc\n def", 2, @"w", 5); }
- (void)test045_WordForwardAtEOL		{ MOVE(@"abc def", 4, @"w", 6); }

- (void)test050_DeleteWordForward		{ TEST(@"abc def", 0, @"dw", @"def", 0); }
- (void)test051_DeleteWordForward2		{ TEST(@"abc def", 1, @"dw", @"adef", 1); }
- (void)test052_DeleteWordForward3		{ TEST(@"abc def", 4, @"dw", @"abc ", 3); }
- (void)test053_DeleteWordForwardAtEol		{ TEST(@"abc def\nghi", 4, @"dw", @"abc \nghi", 3); }
- (void)test054_DeleteWordForwardAtEmptyLine	{ TEST(@"\nabc", 0, @"dw", @"abc", 0); }

- (void)test060_GotoColumnZero			{ MOVE(@"abc def", 4, @"0", 0); }
- (void)test060_GotoColumnZeroWthLeadingBlanks	{ MOVE(@"    def", 4, @"0", 0); }

- (void)test070_DeleteCurrentLine		{ TEST(@"abc\ndef\nghi", 2, @"dd", @"def\nghi", 0); }
- (void)test071_DeleteToColumnZero		{ TEST(@"abc def", 4, @"d0", @"def", 0); }
- (void)test072_DeleteToEOL			{ TEST(@"abc def", 0, @"d$", @"", 0); }
//- (void)test070_DeleteLastLine			{ TEST(@"abc\ndef", 5, @"dd", @"abc", 0); }

- (void)test080_YankWord			{ TEST(@"abc def ghi", 4, @"yw", @"abc def ghi", 4); }
- (void)test080_YankWordAndPaste		{ TEST(@"abc def ghi", 4, @"ywwP", @"abc def def ghi", 8); }
- (void)test081_YankWord2			{ TEST(@"abc def ghi", 8, @"yw0p", @"aghibc def ghi", 1); }
- (void)test082_YankBackwards			{ TEST(@"abcdef", 3, @"y0", @"abcdef", 0); }
- (void)test082_YankBackwardsAndPaste		{ TEST(@"abcdef", 3, @"y0p", @"aabcbcdef", 1); }

@end
