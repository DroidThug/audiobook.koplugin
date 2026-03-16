-- Quick smoke test for splitLongSentence
package.path = "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin/?.lua;" .. package.path

-- Stub logger
package.loaded["logger"] = { dbg = function() end, warn = function() end }

local TextParser = dofile("/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin/textparser.lua")
local tp = TextParser:new()

local function test(label, text)
    local chunks = tp:splitLongSentence(text)
    print(string.format("\n=== %s (%d chars, %d chunks) ===", label, #text, #chunks))
    for i, c in ipairs(chunks) do
        print(string.format("  [%d] %d chars: %.60s%s", i, #c, c, #c > 60 and "..." or ""))
    end
    -- Verify all chunks are within bounds
    for i, c in ipairs(chunks) do
        if #c > 300 then
            print(string.format("  ** FAIL: chunk %d is %d chars (> 300)", i, #c))
        end
    end
end

-- Test 1: short sentence (no split)
test("Short (no split)", "The quick brown fox jumps over the lazy dog.")

-- Test 2: clause-rich long sentence
test("Clause-rich",
    "The old house stood on the hill overlooking the valley; its windows were dark and empty, " ..
    "and the paint had long since peeled away from the wooden siding; the garden, " ..
    "which had once been the pride of the neighborhood, was now overgrown with weeds " ..
    "and wild brambles that reached up to the broken porch railing.")

-- Test 3: many semicolons (adversarial - the pathological case from benchmarks)
test("Many semicolons",
    "First; second; third; fourth; fifth; sixth; seventh; eighth; ninth; tenth; " ..
    "eleventh; twelfth; thirteenth; fourteenth; fifteenth; sixteenth; seventeenth")

-- Test 4: no clause boundaries (must fall through to word-boundary split)
test("No clauses (word-boundary only)",
    string.rep("word ", 80))  -- 400 chars

-- Test 5: very long with mixed boundaries
test("Very long mixed",
    "The researchers discovered that the compound, which had been synthesized in the laboratory " ..
    "using a novel catalytic process, exhibited remarkable properties; it was not only resistant " ..
    "to extreme temperatures, but also demonstrated an unusual ability to conduct electricity " ..
    "at room temperature - a finding that could revolutionize the semiconductor industry, " ..
    "although further testing would be needed before any commercial applications could be developed, " ..
    "and the team acknowledged that significant challenges remained in scaling up production " ..
    "to meet potential industrial demand.")

-- Test 6: position tracking test via parseSentences
print("\n=== Position tracking test ===")
local text = "Short one. " ..
    "The researchers discovered that the compound, which had been synthesized in the laboratory " ..
    "using a novel catalytic process, exhibited remarkable properties; it was not only resistant " ..
    "to extreme temperatures, but also demonstrated an unusual ability to conduct electricity. " ..
    "End sentence."

local sentences = tp:parseSentences(text)
for _, s in ipairs(sentences) do
    local extracted = text:sub(s.start_pos, s.end_pos)
    local match = (extracted == s.text) and "OK" or "MISMATCH"
    print(string.format("  [%d] pos=%d-%d len=%d %s: %.50s%s",
        s.index, s.start_pos, s.end_pos, #s.text, match,
        s.text, #s.text > 50 and "..." or ""))
end

print("\nDone.")
