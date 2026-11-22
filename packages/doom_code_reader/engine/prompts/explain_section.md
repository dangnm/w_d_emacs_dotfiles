Section refresh: explain lines {{target_start}}-{{target_end}} of a source file again, as one section of the file's explanation. The reader asked for this section alone, so only these lines are rewritten.

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}}.{{truncated_note}}

Produce:
- explanation: two to five sentences about the target lines only, in plain prose with no headings or bullet points. Cover the purpose, the key logic, the inputs and outputs, and any side effects. Quote identifiers exactly as written.
- If the lines depend on code outside the snapshot (another file, or a method defined elsewhere), read it with the read-only tools before answering.

<source file="{{file}}">
{{snippet}}
</source>
