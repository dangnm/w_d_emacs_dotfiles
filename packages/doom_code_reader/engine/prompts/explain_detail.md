Detail task: explain lines {{target_start}}-{{target_end}} of a source file line by line, with one entry for each line of code, in file order. The reader is going through the file from top to bottom and wants the decision behind each line: why the writer put it here, and what the rest of the code depends on it for. The snapshot often shows what a line does but not why. The rest of the project usually shows the why.

The section these lines belong to has this explanation. Use it for context only, and do not copy it: each entry is about its own line, not the whole section.
{{section_explanation}}

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}}.{{truncated_note}}

Finding the decision. Do this before you write any entry:
1. Read the comments and the code around the target lines. The writer often recorded the decision there.
2. List the names the target lines use that the snapshot does not define. Include package calls such as "pkg.New" (search for "pkg"), and types, functions, variables, flags and config values.
3. Search the project for each of those names with Grep. One Grep with alternatives (for example "pkg|Pkg") is fine.
4. Read the file that defines each name, and any other file that uses it, so you see its doc comment and who relies on it. Then work out why this line is here and what depends on it.
5. Stop when you can state each decision. Do not map the whole project, and read at most about five other files for the piece.
6. Do not write an entry for a line whose names you have not searched. If the project does not show why this line is here, say so in the first sentence instead of guessing. A name you could not find matters only when it is the reason, so do not mention it otherwise.

Produce:
- lines: an entry for every line from {{target_start}} to {{target_end}} that is not blank, in ascending order. Comment lines and lines that only close a block need an entry too. Each entry has:
  - line: the absolute line number shown in the snapshot (the number before the "|" character).
  - explanation: exactly two plain sentences.
    - The first sentence gives the decision: why this line is here, in plain words a new team member would follow. Name the need it meets or the failure it prevents. Do not lead with what the code does, because the reader can see that. Mention the code only as far as the reason needs it. Name a file only when the reader needs it to find the reason.
    - The second sentence starts with "Without it," and says what would break or change if the line were removed, and which other part of the code that affects. Name other files and functions by name. Use line numbers only for lines in this snapshot.
    - For a comment, the first sentence states the rule or fact the comment records, as a plain statement in your own words. Do not describe the comment: do not start with "The comment", "Explains", "States", "Warns", "Forbids", "Limits" or "Gives the reason". The second sentence says what the reader would lose without it.
    - For a line that only closes a block, the first sentence says what it closes and why that grouping matters, and the second says what would no longer be grouped without it.
    - Give the simplest explanation that is still correct. If there are several reasons, give the main one.
    - Quote identifiers exactly as written. Do not start with "Comment:" or "This line".
- This is an explanation, not a code review. Leave out bugs, compile errors and style remarks, even when you notice them.
- Keep every explanation short, at most about 40 words: the reason, then what breaks without the line. Drop any detail that does not help the reader see one of those two things. The reader reads hundreds of them.

Shape of one explanation (from other code, not from this file): "Stops the scan once the match is found, because later items cannot change the answer. Without it, the loop would keep going and could overwrite the match with a later item."

<source file="{{file}}">
{{snippet}}
</source>
