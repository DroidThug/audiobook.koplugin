--[[--
Long-Sentence Test Document for Piper TTS Benchmark
====================================================
Controlled sentences at increasing lengths (100-1500 chars)
with various clause structures to test splitting strategies.

Each entry is tagged with:
  - target_len:  approximate character count
  - clauses:     number of natural clause boundaries
  - split_hints: natural break points (semicolons, colons, conjunctions, dashes)

@module testdoc_long
--]]

local TestDocLong = {}

--[[--
Sentences grouped by approximate length bucket.
Each bucket contains 2-3 sentences for averaging.
--]]
TestDocLong.sentences = {

    -- ── 100 chars (baseline: well within Piper comfort zone) ────────

    {
        target_len = 100,
        text = "The morning light streamed through the kitchen window and cast long golden shadows across the floor.",
        clauses = 1,
    },
    {
        target_len = 100,
        text = "She picked up the book from the nightstand, opened it carefully, and began to read the first chapter.",
        clauses = 1,
    },

    -- ── 200 chars (efficiency threshold from prior benchmark) ───────

    {
        target_len = 200,
        text = "The old lighthouse keeper had spent forty years watching the sea from his tower, counting the ships that passed in the night and listening to the waves crash against the rocks below, never once complaining about the solitude.",
        clauses = 2,
    },
    {
        target_len = 200,
        text = "Modern text-to-speech systems rely on deep neural networks that learn to map sequences of phonemes to spectrograms, which are then converted into audible waveforms by a separate vocoder model running in real time.",
        clauses = 2,
    },

    -- ── 300 chars ───────────────────────────────────────────────────

    {
        target_len = 300,
        text = "The river wound its way through the valley, passing under ancient stone bridges and beside crumbling castle walls that had stood for centuries; the water was cold and clear, fed by snowmelt from the mountains above, and along its banks grew wildflowers of every imaginable color, attracting butterflies and bees throughout the long summer days.",
        clauses = 3,
    },
    {
        target_len = 300,
        text = "When the committee finally released its report after months of deliberation, the findings were more alarming than anyone had anticipated: rising temperatures were accelerating faster than previous models had predicted, ocean acidity had reached levels not seen in millions of years, and the window for meaningful intervention was narrowing with each passing season.",
        clauses = 4,
    },

    -- ── 400 chars ───────────────────────────────────────────────────

    {
        target_len = 400,
        text = "Throughout the history of human civilization, the ability to record and transmit the spoken word has been one of the most transformative technological achievements, beginning with the invention of writing itself and continuing through the printing press, the telephone, the phonograph, and now digital speech synthesis; each of these milestones fundamentally changed how knowledge was preserved and shared, creating new possibilities for education, commerce, and cultural exchange that previous generations could never have imagined.",
        clauses = 3,
    },
    {
        target_len = 400,
        text = "The architect stood before the city council and described her vision for the waterfront development: a series of interconnected parks and public spaces that would stretch for nearly two kilometers along the shoreline, incorporating sustainable design principles such as rainwater harvesting, native plantings, and permeable surfaces, while also providing space for outdoor markets, performance venues, and community gardens - all connected by a continuous pedestrian promenade with views of the harbor.",
        clauses = 4,
    },

    -- ── 500 chars ───────────────────────────────────────────────────

    {
        target_len = 500,
        text = "In the early days of artificial intelligence research, most scientists believed that achieving human-level language understanding would require systems that could reason about the world in much the same way that people do, building mental models of physical objects, social relationships, and causal chains; however, the remarkable success of large language models trained purely on text data has challenged this assumption, suggesting that statistical patterns in language may encode far more world knowledge than anyone previously suspected, although critics point out that these systems still fail at tasks requiring genuine physical intuition or the kind of common-sense reasoning that even young children perform effortlessly.",
        clauses = 5,
    },
    {
        target_len = 500,
        text = "The expedition had been planned for over three years, but nothing could have prepared the team for what they encountered when they finally reached the cave system deep beneath the limestone plateau: vast chambers decorated with stalactites that had been growing for millennia, underground rivers that carved through the rock in complete darkness, and fossils of creatures that had lived and died long before the first humans walked the earth - all of it untouched, pristine, and utterly silent except for the distant echo of dripping water that seemed to come from everywhere and nowhere at once, a sound that would haunt their dreams for years afterward.",
        clauses = 6,
    },

    -- ── 600 chars ───────────────────────────────────────────────────

    {
        target_len = 600,
        text = "The challenge of running neural text-to-speech models on embedded devices like e-readers is fundamentally a problem of computational economics: the inference pass through a typical neural vocoder requires billions of floating-point operations per second of generated audio, and while modern smartphones can handle this workload thanks to their multi-core processors and dedicated neural accelerators, an e-reader built around a low-power ARM Cortex processor clocked at barely one gigahertz must somehow accomplish the same task with a fraction of the computational budget; this means that every optimization matters - from quantizing model weights to reduce memory bandwidth, to batching multiple sentences together to amortize the fixed overhead of model loading, to carefully scheduling work across available cores so that one sentence can be synthesized while the previous one plays back through the audio pipeline.",
        clauses = 5,
    },
    {
        target_len = 600,
        text = "Maria had always believed that the small coastal town where she grew up was the most beautiful place in the world, and even after spending a decade living in some of the grandest cities of Europe - Paris with its elegant boulevards and centuries of artistic heritage, Vienna with its coffee houses and orchestral tradition, Barcelona with its sun-drenched plazas and Gaudi's fantastical architecture - she never changed her mind; there was something about the way the morning fog rolled in from the sea and settled in the harbor, the sound of fishing boats returning at dawn, the smell of salt and pine and wildflowers carried on the afternoon breeze, that no amount of metropolitan sophistication could ever hope to replicate or replace in her heart.",
        clauses = 5,
    },

    -- ── 800 chars ───────────────────────────────────────────────────

    {
        target_len = 800,
        text = "The history of attempts to create machines that can speak stretches back further than most people realize, beginning not with computers but with elaborate mechanical devices built in the eighteenth century: Wolfgang von Kempelen, better known for his fraudulent chess-playing automaton, actually constructed a genuine speaking machine in 1791 that used bellows, reeds, and a flexible leather resonating chamber to produce recognizable vowel sounds and even a few consonants; Charles Wheatstone later improved upon this design in the 1830s, and by the early twentieth century, researchers at Bell Labs had created the Voder, an electronic device that could be played like a musical instrument by a trained operator to produce intelligible speech - a demonstration that caused a sensation at the 1939 World's Fair; yet despite these remarkable achievements, truly natural-sounding synthetic speech would remain elusive for another sixty years, until the combination of vast text corpora, powerful neural networks, and sufficient computational resources finally made it possible.",
        clauses = 7,
    },

    -- ── 1000 chars ──────────────────────────────────────────────────

    {
        target_len = 1000,
        text = "One of the most persistent challenges in deploying machine learning models on resource-constrained hardware is the fundamental tension between model quality and inference speed, a trade-off that manifests differently depending on the specific constraints of the target platform; on a device like the Kobo Clara, which features a dual-core ARM Cortex-A7 processor running at approximately one gigahertz with only 512 megabytes of RAM, the situation is particularly acute because the processor lacks not only the raw clock speed of a modern smartphone chip but also the SIMD extensions, hardware floating-point pipelines, and cache hierarchies that make neural network inference practical on more capable platforms; consequently, a model that runs comfortably in real time on a Raspberry Pi 4 might take three or four times longer on the Kobo, which means that strategies which seem unnecessary on faster hardware - such as splitting long sentences into smaller chunks before synthesis, pre-computing the next sentence while the current one plays, or using reduced-precision arithmetic throughout the inference pipeline - become absolutely essential for delivering an acceptable user experience on these deeply embedded devices.",
        clauses = 6,
    },

    -- ── 1200 chars ──────────────────────────────────────────────────

    {
        target_len = 1200,
        text = "The question of how to handle extremely long sentences in a text-to-speech pipeline running on constrained hardware admits several possible answers, each with its own set of trade-offs that must be carefully weighed against the specific requirements of the application and the expectations of the user; the simplest approach is to feed the entire sentence to the synthesis engine unchanged and accept whatever processing time results, which has the advantage of preserving the natural prosody and intonation patterns that the neural model has learned to produce for complete grammatical units, but the serious disadvantage that a sentence of eight hundred or more characters might require ninety seconds or longer to synthesize on a slow ARM processor, during which time the user is left waiting in silence with no indication of progress; a second approach is to split the sentence at natural clause boundaries such as semicolons, colons, or coordinating conjunctions, which reduces the maximum chunk size while still preserving reasonably natural speech patterns at the boundaries, though it requires a parser sophisticated enough to identify these boundaries reliably without creating fragments that sound awkward when spoken in isolation; a third possibility is simple fixed-length chunking at word boundaries, which guarantees predictable synthesis times but may produce splits in the middle of phrases that disrupt the natural rhythm of speech.",
        clauses = 8,
    },

    -- ── 1500 chars ──────────────────────────────────────────────────

    {
        target_len = 1500,
        text = "When we consider the full pipeline from text on the screen to sound in the listener's ear, it becomes clear that the synthesis step is only one of several stages where latency can accumulate and where intelligent optimization can make the difference between an experience that feels fluid and responsive and one that feels sluggish and frustrating; first, the text must be extracted from the document and segmented into manageable units, a process that involves parsing the document format, identifying paragraph and sentence boundaries, handling special characters and abbreviations, and dealing with the various edge cases that real-world text inevitably presents - such as sentences that span multiple paragraphs, dialogue interspersed with attribution tags, or technical content containing numbers, acronyms, and inline code; second, each unit of text must be converted into a sequence of phonemes by the text-to-phoneme front end, which itself may involve dictionary lookups, grapheme-to-phoneme rules, and language-specific post-processing for things like homograph disambiguation and prosodic phrasing; third, the phoneme sequence must be passed through the neural acoustic model to generate a spectrogram or similar intermediate representation, which is typically the most computationally expensive step in the entire pipeline; fourth, the spectrogram must be converted to an audio waveform by the vocoder, which on constrained hardware may require nearly as much computation as the acoustic model itself; and finally, the audio samples must be written to a buffer and played back through the audio subsystem, which on a device like the Kobo involves routing through ALSA or a GStreamer pipeline to either the built-in speaker or a Bluetooth audio device, each of which introduces its own characteristic latency.",
        clauses = 10,
    },

    -- ── Adversarial: no natural clause boundaries ───────────────────

    {
        target_len = 500,
        text = "The incredibly detailed and painstakingly hand-painted mural covering the entire north wall of the renovated nineteenth-century industrial warehouse turned contemporary art gallery depicted a sprawling panoramic scene of the ancient Mediterranean port city as it might have appeared during the height of the Roman Empire with hundreds of tiny figures going about their daily business in the crowded marketplace while enormous grain ships sailed into the harbor and soldiers in gleaming armor patrolled the colonnaded streets beneath a sky rendered in the most extraordinary shades of gold and amber and deep Mediterranean blue.",
        clauses = 1,
    },

    -- ── Adversarial: many short clauses ─────────────────────────────

    {
        target_len = 400,
        text = "He ran; she followed; the dog barked; the cat hissed; the birds scattered; the neighbor looked out; the mailman stopped; the children laughed; the sprinkler turned on; the car alarm went off; the phone rang; nobody answered; the wind picked up; the clouds gathered; thunder rolled in the distance; the first drops of rain began to fall; and still they kept running, faster and faster, around the block and through the park and down the hill toward the lake.",
        clauses = 17,
    },

    -- ── Adversarial: long list with commas ──────────────────────────

    {
        target_len = 600,
        text = "The recipe called for an extraordinary number of ingredients that had to be assembled before beginning the cooking process, including fresh basil, dried oregano, crushed red pepper flakes, whole black peppercorns, sea salt, extra virgin olive oil, aged balsamic vinegar, sun-dried tomatoes packed in oil, kalamata olives, roasted garlic cloves, shaved parmesan cheese, toasted pine nuts, artichoke hearts, capers, anchovies, fresh mozzarella, prosciutto, arugula, radicchio, fennel, red onion, cherry tomatoes, sweet bell peppers, zucchini, eggplant, portobello mushrooms, and a generous handful of fresh flat-leaf parsley, all of which needed to be carefully washed, chopped, measured, and arranged on the counter before a single pan was placed on the stove.",
        clauses = 2,
    },
}

--[[--
Get all sentences with metadata.
@return table Array of {text, target_len, clauses}
--]]
function TestDocLong:getSentences()
    return self.sentences
end

--[[--
Get sentences in a specific length range.
@param min_len number Minimum character count
@param max_len number Maximum character count
@return table Filtered sentences
--]]
function TestDocLong:getSentencesByLength(min_len, max_len)
    local result = {}
    for _, s in ipairs(self.sentences) do
        local len = #s.text
        if len >= min_len and len <= max_len then
            table.insert(result, s)
        end
    end
    return result
end

--[[--
Get summary statistics.
@return table Stats
--]]
function TestDocLong:getStats()
    local total_chars = 0
    local min_len = math.huge
    local max_len = 0
    local lengths = {}
    for _, s in ipairs(self.sentences) do
        local len = #s.text
        total_chars = total_chars + len
        min_len = math.min(min_len, len)
        max_len = math.max(max_len, len)
        table.insert(lengths, len)
    end
    table.sort(lengths)
    return {
        count = #self.sentences,
        total_chars = total_chars,
        min_len = min_len,
        max_len = max_len,
        median_len = lengths[math.ceil(#lengths / 2)] or 0,
        avg_len = total_chars / math.max(1, #self.sentences),
        lengths = lengths,
    }
end

return TestDocLong
