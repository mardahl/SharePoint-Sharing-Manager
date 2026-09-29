"""Convert `tmux capture-pane -e -p` output (ANSI SGR) to a terminal-window SVG.

Usage: ansi2svg.py INPUT.ans OUTPUT.svg

Supports 16/256/truecolor fg/bg, bold, dim, underline and reverse. Every
character is treated as one cell (130x34 grid, 8.4x17 px per cell). Words are
placed individually with textLength so alignment does not depend on the font.
"""
import re,sys,html
CW,CH=8.4,17.0
DFG,DBG='#d4d4d4','#1e1e1e'
B16=['#000000','#cd3131','#0dbc79','#e5e510','#2472c8','#bc3fbc','#11a8cd','#e5e5e5','#666666','#f14c4c','#23d18b','#f5f543','#3b8eea','#d670d6','#29b8db','#ffffff']
def p256(n):
    if n<16:return B16[n]
    if n<232:
        n-=16;v=[0,95,135,175,215,255];return '#%02x%02x%02x'%(v[n//36],v[n//6%6],v[n%6])
    g=8+(n-232)*10;return '#%02x%02x%02x'%(g,g,g)
def parse(text,cols):
    rows=[]
    st=dict(fg=None,bg=None,b=False,r=False,u=False,d=False)
    for line in text.split('\n'):
        cells=[];i=0
        while i<len(line):
            c=line[i]
            if c=='\x1b':
                m=re.match(r'\x1b\[([0-9;:]*)([A-Za-z])',line[i:])
                if not m: i+=1;continue
                i+=m.end()
                if m.group(2)!='m':continue
                a=[int(x) if x else 0 for x in re.split('[;:]',m.group(1))] or [0]
                j=0
                while j<len(a):
                    x=a[j]
                    if x==0: st.update(fg=None,bg=None,b=False,r=False,u=False,d=False)
                    elif x==1: st['b']=True
                    elif x==2: st['d']=True
                    elif x==22: st['b']=False;st['d']=False
                    elif x==4: st['u']=True
                    elif x==24: st['u']=False
                    elif x==7: st['r']=True
                    elif x==27: st['r']=False
                    elif 30<=x<=37: st['fg']=B16[x-30]
                    elif 90<=x<=97: st['fg']=B16[x-90+8]
                    elif 40<=x<=47: st['bg']=B16[x-40]
                    elif 100<=x<=107: st['bg']=B16[x-100+8]
                    elif x==39: st['fg']=None
                    elif x==49: st['bg']=None
                    elif x in(38,48):
                        k='fg' if x==38 else 'bg'
                        if a[j+1]==5: st[k]=p256(a[j+2]);j+=2
                        elif a[j+1]==2: st[k]='#%02x%02x%02x'%tuple(a[j+2:j+5]);j+=4
                    j+=1
                continue
            fg=st['fg'] or DFG;bg=st['bg'] or DBG
            if st['r']:fg,bg=bg,fg
            cells.append((c,fg,bg,st['b'],st['u'],st['d']));i+=1
        cells=cells[:cols]+[(' ',DFG,DBG,False,False,False)]*(cols-len(cells))
        rows.append(cells)
    return rows
def runs(cells,key):
    out=[];
    for x,c in enumerate(cells):
        k=key(c)
        if out and out[-1][0]==k:out[-1][2]+=1
        else:out.append([k,x,1])
    return out
def svg(text,title,cols,rows_n):
    rows=parse(text.rstrip('\n'),cols)[:rows_n]
    while len(rows)<rows_n:rows.append([(' ',DFG,DBG,False,False,False)]*cols)
    P=14;TB=34;W=cols*CW+2*P;H=rows_n*CH+2*P+TB
    o=['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="%s">'%(W,H,W,H,html.escape(title)),
    '<rect width="%d" height="%d" rx="10" fill="#1e1e1e" stroke="#3a3a3a"/>'%(W,H),
    '<path d="M0 10a10 10 0 0 1 10-10h%da10 10 0 0 1 10 10v%dH0z" fill="#2d2d2d"/>'%(W-20,TB-10),
    '<circle cx="20" cy="17" r="6" fill="#ff5f57"/><circle cx="40" cy="17" r="6" fill="#febc2e"/><circle cx="60" cy="17" r="6" fill="#28c840"/>',
    '<text x="%s" y="22" text-anchor="middle" fill="#9a9a9a" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="13">%s</text>'%(W/2,html.escape(title)),
    '<g transform="translate(%d,%d)" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace" font-size="14">'%(P,TB+P)]
    for y,cells in enumerate(rows):
        for k,x,n in runs(cells,lambda c:c[2]):
            if k!=DBG:o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'%(x*CW,y*CH,n*CW+.3,CH+.3,k))
    for y,cells in enumerate(rows):
        for k,x,n in runs(cells,lambda c:(c[1],c[3],c[4],c[5])):
            fg,b,u,d=k
            for m in re.finditer(r'\S+',''.join(c[0] for c in cells[x:x+n])):
                t=m.group(0);sx=x+m.start()
                o.append('<text x="%.1f" y="%.1f" fill="%s"%s%s%s textLength="%.1f" lengthAdjust="spacing">%s</text>'%(sx*CW,y*CH+CH-4.5,fg,' font-weight="bold"' if b else '',' text-decoration="underline"' if u else '',' opacity=".6"' if d else '',len(t)*CW,html.escape(t)))
    o.append('</g></svg>')
    return '\n'.join(o)
if __name__=='__main__':
    src,dst=sys.argv[1:3]
    open(dst,'w').write(svg(open(src).read(),'SharePoint Sharing Manager',130,34))
