-- Populate a freshly initialized projects.sqlite; disposable test profiles only.
.bail on
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5000)
INSERT INTO projects(position,id,name,created_at)
SELECT x, printf('00000000-0000-4000-8000-%012d', x), printf('Fixture Project %d',x), 1 FROM n;

WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
INSERT INTO threads(position,id,project_id,title,automatic_title,archived,created_at,updated_at)
SELECT x, printf('10000000-0000-4000-8000-%012d', x),
       printf('00000000-0000-4000-8000-%012d', min((x-1)/19+1,5000)),
       printf('Fixture Thread %d',x), 0, x%7=0, 1, 1 FROM n;

UPDATE navigation SET thread_id = '10000000-0000-4000-8000-000000100000';
UPDATE threads SET next_sequence = 100001 WHERE position = 100000;
INSERT INTO preferences VALUES ('10000000-0000-4000-8000-000000100000',
    '{"draft":"Fixture draft","effort":"medium","speed":"standard"}');

WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
INSERT INTO entries(thread_id,sequence,id,turn_id,role,status,preview,body_bytes,created_at)
SELECT '10000000-0000-4000-8000-000000100000', x,
       printf('20000000-0000-4000-8000-%012d', x), printf('30000000-0000-4000-8000-%012d', (x+1)/2),
       CASE x%2 WHEN 1 THEN 'user' ELSE 'assistant' END,1,
       printf('Fixture message %d',x), length(printf('Fixture message %d',x)),1 FROM n;

INSERT INTO bodies SELECT id,0,preview FROM entries WHERE sequence <> 100000;
WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<15)
INSERT INTO bodies SELECT '20000000-0000-4000-8000-000000100000', x,
    replace(hex(zeroblob(32768)), '0', 'x') FROM n;
UPDATE entries SET preview = replace(hex(zeroblob(2560)), '0', 'x'),
    body_bytes = 1048576, tool_count = 1
WHERE sequence = 100000;
INSERT INTO tools(entry_id,call_id,name,summary,arguments,result,success)
VALUES ('20000000-0000-4000-8000-000000100000','fixture-tool','read_file','Read fixture.txt','{}',
        replace(hex(zeroblob(16000)), '0', 'y'),1);
COMMIT;
