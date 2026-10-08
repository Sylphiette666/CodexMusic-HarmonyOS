import subprocess,json,re,sys,time,pathlib
ROOT=pathlib.Path(__file__).resolve().parent.parent/'docs'
ROOT.mkdir(exist_ok=True)
(ROOT/'screenshots').mkdir(exist_ok=True)
HDC=r'D:\HUAWEI\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
BASE=[HDC,'-t','127.0.0.1:5555']
def run(*args):
 p=subprocess.run(BASE+list(args),capture_output=True,encoding='utf-8',errors='replace',timeout=30)
 if p.returncode: raise RuntimeError(p.stdout+p.stderr)
 return p.stdout
def layout():
 run('shell','uitest','dumpLayout','-p','/data/local/tmp/codexmusic-layout.json')
 run('file','recv','/data/local/tmp/codexmusic-layout.json',str(ROOT/'layout.json'))
 tree=json.loads((ROOT/'layout.json').read_text(encoding='utf-8'))
 nodes=[]
 def walk(n):
  if isinstance(n,dict):
   a=n.get('attributes',{})
   if a: nodes.append(a)
   for c in n.get('children',[]): walk(c)
 walk(tree)
 return nodes
def element(id):
 matches=[x for x in layout() if x.get('id')==id]
 if len(matches)!=1: raise RuntimeError('Expected unique '+id+', found '+str(len(matches)))
 return matches[0]
def center(a):
 b=[int(x) for x in re.findall(r'-?\d+',a['bounds'])]
 return str((b[0]+b[2])//2),str((b[1]+b[3])//2)
def tap(id):
 x,y=center(element(id));run('shell','uitest','uiInput','click',x,y);time.sleep(.4)
def enter(id,text):
 x,y=center(element(id));run('shell','uitest','uiInput','inputText',x,y,text);time.sleep(.3)
def back():
 run('shell','uitest','uiInput','keyEvent','Back');time.sleep(.4)
def screenshot(name):
 remote='/data/local/tmp/course-'+name+'.jpeg'
 run('shell','snapshot_display','-f',remote)
 run('file','recv',remote,str(ROOT/'screenshots'/(name+'.jpeg')))
 print('Screenshot:',name)
def observe():
 for a in layout():
  if a.get('text') or a.get('id'):
   print(json.dumps({k:a.get(k) for k in ['id','text','bounds']},ensure_ascii=False))
if __name__=='__main__':
 action=sys.argv[1]
 if action=='tap': tap(sys.argv[2])
 elif action=='input': enter(sys.argv[2],sys.argv[3])
 elif action=='back': back()
 elif action=='shot': screenshot(sys.argv[2])
 observe()
