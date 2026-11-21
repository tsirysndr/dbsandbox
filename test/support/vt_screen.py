"""Minimal cell buffer for the cursor-positioned output used by OpenTUI tests."""
import re, unicodedata

class Screen:
    def __init__(self, columns, rows):
        self.pending='';self.x=0;self.y=0;self.saved=(0,0);self.resize(columns,rows)
    def resize(self, columns, rows):
        self.columns=columns;self.rows=rows;self.cells=[[' ']*columns for _ in range(rows)]
    def frame(self): return '\n'.join(''.join(row) for row in self.cells)
    def feed(self, text):
        value=self.pending+text;i=0
        while i<len(value):
            c=value[i]
            if c=='\x1b':
                if i+1>=len(value): break
                kind=value[i+1]
                if kind=='[':
                    match=re.match(r'\x1b\[([0-?]*)([ -/]*)([@-~])',value[i:])
                    if not match: break
                    raw,_,command=match.groups();params=[int(n) if n.isdigit() else 0 for n in raw.lstrip('?><!').split(';')]
                    first=params[0] if params else 0
                    if command in ['H','f']:
                        self.y=max(0,(first or 1)-1);self.x=max(0,((params[1] if len(params)>1 else 1) or 1)-1)
                    elif command=='G': self.x=max(0,(first or 1)-1)
                    elif command=='A': self.y=max(0,self.y-(first or 1))
                    elif command=='B': self.y+=first or 1
                    elif command=='C': self.x+=first or 1
                    elif command=='D': self.x=max(0,self.x-(first or 1))
                    elif command=='s': self.saved=(self.x,self.y)
                    elif command=='u': self.x,self.y=self.saved
                    elif command=='J':
                        if first==2: self.cells=[[' ']*self.columns for _ in range(self.rows)]
                        elif first==0 and self.y<self.rows:
                            self.cells[self.y][min(self.x,self.columns):]=[' ']*max(0,self.columns-self.x)
                            for row in range(self.y+1,self.rows):self.cells[row]=[' ']*self.columns
                    elif command=='K' and self.y<self.rows:
                        start=0 if first in [1,2] else min(self.x,self.columns);end=min(self.x+1,self.columns) if first==1 else self.columns
                        self.cells[self.y][start:end]=[' ']*(end-start)
                    i+=len(match.group());continue
                if kind in [']','P','_','^']:
                    bell=value.find('\x07',i+2);st=value.find('\x1b\\',i+2)
                    ends=[(bell,1),(st,2)];ends=[p for p in ends if p[0]>=0]
                    if not ends:break
                    end,length=min(ends);i=end+length;continue
                i+=2;continue
            if c=='\r': self.x=0
            elif c=='\n': self.y=min(self.rows-1,self.y+1)
            elif c=='\b': self.x=max(0,self.x-1)
            elif c=='\t': self.x=((self.x//8)+1)*8
            elif ord(c)>=32 and ord(c)!=127:
                width=0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ['W','F'] else 1
                if 0<=self.y<self.rows and 0<=self.x<self.columns:self.cells[self.y][self.x]=c
                self.x+=width
            i+=1
        self.pending=value[i:]
