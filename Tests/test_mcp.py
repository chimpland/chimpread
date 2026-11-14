"""MCP interoperability test against the official Python SDK, using disposable PDFs."""
import asyncio
import hashlib
import json
import sqlite3
from pathlib import Path
import subprocess
import tempfile
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

APP = Path(__file__).resolve().parents[1] / 'build/chimpread.app/Contents/MacOS/chimpread'

async def main():
    with tempfile.TemporaryDirectory(prefix='chimpread-mcp-test-') as temp:
        root = Path(temp) / 'library'
        subprocess.run([str(APP), '--make-demo', str(root)], check=True, capture_output=True)
        papers = json.loads((root / 'library.json').read_text())['papers']
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (root / 'PDFs').iterdir()}
        params = StdioServerParameters(command=str(APP), args=['--mcp', '--library', str(root)])
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                init = await session.initialize()
                print('PASS SDK initialization', init.protocol_version)
                tools = await session.list_tools()
                assert {t.name for t in tools.tools} == {'search_papers', 'get_paper', 'read_pages', 'read_notes', 'search_passages', 'get_index_status', 'propose_collection'}
                assert all(t.annotations.read_only_hint == (t.name != 'propose_collection') for t in tools.tools)
                assert (await session.call_tool('search_papers', {})).is_error
                (root/'mcp-access.json').write_text(json.dumps({'enabled':True,'includeContent':False}))
                found = await session.call_tool('search_papers', {'collection':'Reading room'})
                assert not found.is_error and json.loads(found.content[0].text)['total'] == 3
                assert (await session.call_tool('read_pages', {'paper_id':papers[0]['id'], 'start_page':1})).is_error
                assert (await session.call_tool('search_passages', {'query':'demonstration'})).is_error
                proposal = {'paper_ids':[papers[0]['id']], 'collection':'Proposed research', 'reason':'Synthetic test'}
                assert (await session.call_tool('propose_collection', proposal)).is_error
                status = await session.call_tool('get_index_status', {})
                assert not status.is_error and json.loads(status.content[0].text)['status'] == 'not_indexed'
                assert not (root/'ResearchIndex').exists()
                print('PASS SDK discovery, legacy permissions and metadata-only gate')
                (root/'mcp-access.json').write_text(json.dumps({'enabled':True,'includeContent':True}))
                result = await session.call_tool('read_pages', {'paper_id':papers[0]['id'], 'start_page':2,'page_count':2})
                assert not result.is_error
                payload = json.loads(result.content[0].text)
                assert [p['page'] for p in payload['pages']] == [2,3]
                assert 'demonstration PDF' in payload['pages'][0]['text']
                assert not (await session.call_tool('read_notes', {'paper_id':papers[0]['id']})).is_error
                for invalid in [0, -1, True, '1', 1.5, 99999]:
                    assert (await session.call_tool('read_pages', {'paper_id':papers[0]['id'],'start_page':invalid})).is_error
                assert sum(len(page['text']) for page in payload['pages']) <= 24000
                # Seed a disposable evidence cache; MCP must only query, never index.
                cache = root/'ResearchIndex'
                cache.mkdir()
                with sqlite3.connect(cache/'evidence-v1.sqlite') as db:
                    db.execute('CREATE TABLE documents(id TEXT PRIMARY KEY,title TEXT NOT NULL,revision TEXT NOT NULL,status TEXT NOT NULL,pages INTEGER NOT NULL)')
                    db.execute("CREATE VIRTUAL TABLE passages USING fts5(paper UNINDEXED,title,text,page UNINDEXED,revision UNINDEXED,tokenize='unicode61')")
                    for p in papers:
                        revision = before[p['filename']]
                        db.execute('INSERT INTO documents VALUES(?,?,?,?,?)', (p['id'],p['title'],revision,'complete',1))
                        db.execute('INSERT INTO passages VALUES(?,?,?,?,?)', (p['id'],p['title'],'synthetic evidence passage',1,revision))
                evidence = await session.call_tool('search_passages', {'query':'synthetic','collection':'Reading room'})
                assert not evidence.is_error and len(json.loads(evidence.content[0].text)['hits']) == 3
                index_path = root/'library.json'
                library = json.loads(index_path.read_text())
                library['papers'][0]['archived'] = True
                index_path.write_text(json.dumps(library))
                evidence = await session.call_tool('search_passages', {'query':'synthetic'})
                assert len(json.loads(evidence.content[0].text)['hits']) == 2
                library['papers'][0]['archived'] = False
                library['papers'][0]['notes'] = 'N' * 40000
                index_path.write_text(json.dumps(library))
                notes = json.loads((await session.call_tool('read_notes', {'paper_id':papers[0]['id']})).content[0].text)
                assert len(notes['library_notes']) + sum(len(n['text']) for n in notes['annotations']) <= 24000
                (root/'mcp-access.json').write_text(json.dumps({'enabled':True,'includeContent':True,'includeProposals':True}))
                canonical_before = index_path.read_bytes()
                submitted = await session.call_tool('propose_collection', proposal)
                assert not submitted.is_error and not json.loads(submitted.content[0].text)['applied']
                assert index_path.read_bytes() == canonical_before
                assert len(json.loads((root/'research-plans.json').read_text())['pending']) == 1
                await session.call_tool('propose_collection', proposal)
                assert len(json.loads((root/'research-plans.json').read_text())['pending']) == 1
                invalid = dict(proposal, paper_ids=[papers[0]['id']]*51)
                assert (await session.call_tool('propose_collection', invalid)).is_error
                print('PASS SDK bounded content, evidence scopes, proposal permission and no canonical mutation')
                (root/'mcp-access.json').write_text('{bad json')
                assert (await session.call_tool('search_papers', {})).is_error
                print('PASS malformed permission file fails closed in existing session')
        after = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (root / 'PDFs').iterdir()}
        assert before == after
        print('PASS MCP leaves every PDF byte unchanged')
        # Oversized framing is drained before JSON parsing; the next request works.
        request = json.dumps({'jsonrpc':'2.0','id':77,'method':'ping'}).encode()
        framed = subprocess.run([str(APP),'--mcp','--library',str(root)], input=b'x'*(1048576+10)+b'\n'+request+b'\n', capture_output=True, check=True, timeout=20)
        responses = [json.loads(line) for line in framed.stdout.splitlines()]
        assert len(responses) == 2 and responses[0]['error']['code'] == -32600
        assert responses[1]['id'] == 77 and responses[1]['result'] == {}
        print('PASS bounded oversized frame recovery')

asyncio.run(asyncio.wait_for(main(), timeout=90))
