import Testing
@testable import VibeFlowCore

@Suite("SpeakableText")
struct SpeakableTextTests {
    @Test func markdownTableReadsAsHeaderValueSentences() {
        let table = """
        | Campaign | Ad set | Budget | Ads |
        |---|---|---|---|
        | GLE membership acquisition | Publishing / visibility | Allocated test budget | Discovery, workload and specialism creatives |
        | Same campaign | Networking | Equal initial test budget | Introductions and overseas relationships creatives |
        """
        #expect(SpeakableText.make(table) == """
        Campaign: GLE membership acquisition, Ad set: Publishing or visibility, Budget: Allocated test budget, Ads: Discovery, workload and specialism creatives.
        Campaign: Same campaign, Ad set: Networking, Budget: Equal initial test budget, Ads: Introductions and overseas relationships creatives.
        """)
    }

    @Test func linkReadsAsItsText() {
        let link = "[Meta’s campaign settings](https://github.com/facebook/facebook-python-business-sdk/blob/main/facebook_business/adobjects/campaign.py)"
        #expect(SpeakableText.make(link) == "Meta’s campaign settings")
        #expect(SpeakableText.make("See [the docs](https://x.com/a \"Docs\") first.") == "See the docs first.")
    }

    @Test func bareURLsReadAsTheirDomain() {
        #expect(SpeakableText.make("Details at https://www.example.com/path?q=1.") == "Details at example.com.")
        #expect(SpeakableText.make("Source: <https://github.com/a/b>") == "Source: github.com")
        #expect(SpeakableText.make("(see https://docs.groq.com/api)") == "(see docs.groq.com)")
    }

    @Test func tableAmidProseKeepsTheProse() {
        let text = "Two ad sets:\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nThat is all."
        #expect(SpeakableText.make(text) == "Two ad sets:\n\nA: 1, B: 2.\n\nThat is all.")
    }

    @Test func tabSeparatedSpreadsheetRows() {
        let text = "Name\tRole\nAnna\tLawyer\nBen\t"
        #expect(SpeakableText.make(text) == "Name: Anna, Role: Lawyer.\nName: Ben.")
    }

    @Test func pipeRowsWithoutAHeaderAreReadAsLists() {
        #expect(SpeakableText.make("| a | b |\n| c | d |") == "a, b.\nc, d.")
    }

    @Test func markdownMarksDisappearAndListsPause() {
        let md = """
        ## Next steps
        - **Launch** the `networking` ad set
        - Review _results_ on Friday
        1. Pause losers
        > Quoted note
        ---
        """
        #expect(SpeakableText.make(md) == """
        Next steps.
        Launch the networking ad set.
        Review results on Friday.
        Pause losers.
        Quoted note
        """)
    }

    @Test func codeFencesAreDroppedButCodeIsKept() {
        #expect(SpeakableText.make("Run:\n```bash\nswift test\n```") == "Run:\nswift test")
    }

    @Test func plainProseIsUnchanged() {
        let prose = "Dear Anna,\n\nThe budget is €4,000 (net). Use snake_case_names and 2*3 = 6.\nThanks, Ben"
        #expect(SpeakableText.make(prose) == prose)
    }

    @Test func symbolsBecomeWords() {
        #expect(SpeakableText.make("Leads -> Sales & Booking") == "Leads to Sales and Booking")
        #expect(SpeakableText.make("Tom &amp; Jerry") == "Tom & Jerry")
        #expect(SpeakableText.make("Use \\*literal\\* stars") == "Use *literal* stars")
    }
}

@Suite("ReadSession speaks the listening form") @MainActor
struct SpeakableReadTests {
    @Test func linksAndTablesAreRewrittenBeforeTheVoice() async {
        let h = SessionHarness { $0.capture.result = CaptureResult(text: "Read [the settings](https://github.com/a/b.py) now.") }
        h.session.hotkey(.read)
        await h.settle()
        #expect(h.elevenLabs.requests.first?.text == "Read the settings now.")
    }
}
