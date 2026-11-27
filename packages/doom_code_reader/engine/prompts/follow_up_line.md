Task: answer a question from the reader about line {{line}} of a source file. Line {{line}} is one of the lines {{target_start}}-{{target_end}}. The reader has already seen the explanation of this file, and the detail explanation of this line, so the answer should add to them, not repeat them.

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Line: {{line}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}}.{{truncated_note}}

The line:
{{line_code}}

The detail explanation already given for this line:
{{line_explanation}}

Question from the reader about line {{line}}:
{{question}}

Produce:
- answer: a direct answer to the question, about line {{line}}. Start with the answer. Use short paragraphs or a few bullets, under 250 words. Quote identifiers exactly as written.
- If the answer depends on code outside the snapshot (another file, a constant, a method defined elsewhere), read it with the read-only tools before answering, and name the file you read. If the question is not about this line or this code, say so in one sentence.

<source file="{{file}}">
{{snippet}}
</source>
