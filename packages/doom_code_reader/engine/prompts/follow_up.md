Task: answer a question from the reader about lines {{target_start}}-{{target_end}} of a source file. The reader has already seen the explanation of this file, so the answer should add to it, not repeat it.

File: {{file}}
Language: {{language}}
Project root: {{project_root}}
Target lines: {{target_start}}-{{target_end}}
Snapshot shows lines {{window_start}}-{{window_end}} of {{total_lines}}.{{truncated_note}}

Question from the reader:
{{question}}

Produce:
- answer: a direct answer to the question, about the target lines. Start with the answer. Use short paragraphs or a few bullets, under 250 words. Quote identifiers exactly as written.
- If the answer depends on code outside the snapshot (another file, a constant, a method defined elsewhere), read it with the read-only tools before answering, and name the file you read. If the question is not about this code, say so in one sentence.

<source file="{{file}}">
{{snippet}}
</source>
