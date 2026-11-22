Detail task: explain lines {{target_start}}-{{target_end}} of a source file line by line, with one entry for each line of code, in file order. The reader is going through the file from top to bottom and wants to know what each line does. The section they are reading already has a short explanation, so each entry says what its own line does, not what the whole section does.

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}}.{{truncated_note}}

Produce:
- lines: an entry for every line from {{target_start}} to {{target_end}} that is not blank, in ascending order. Comment lines and lines that only close a block need an entry too. Each entry has:
  - line: the absolute line number shown in the snapshot (the number before the "|" character).
  - explanation: one or two plain sentences saying what this line does and, when it is not obvious, why. For a line that only closes a block, say what it closes. Quote identifiers exactly as written. Do not repeat the code.
- Keep every explanation short. The reader reads hundreds of them.
- Only read other files when a line cannot be explained from the snapshot, and name the file you read.

<source file="{{file}}">
{{snippet}}
</source>
