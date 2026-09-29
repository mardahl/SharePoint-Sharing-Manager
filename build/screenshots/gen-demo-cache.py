"""Write a fictional contoso demo config and scan cache for the screenshots.

Usage: gen-demo-cache.py CONFIG.json SESSION.json

Deterministic (fixed seed). All names and domains are fictional
(contoso, fabrikam, northwind).
"""
import json,random,datetime,sys
random.seed(11)
now=datetime.datetime(2026,9,20)
CAT={'AnonymousLink':'Anonymous link','OrgLink':'Organization link','GuestLink':'Guest-specific link','GuestGrant':'Guest grant','EEEU':'EEEU grant'}
FILES=['Q3-Budget.xlsx','Payroll-2026.xlsx','Contract-Draft.docx','Board-Deck.pptx','Customer-List.csv','Roadmap.pdf','Salary-Bands.xlsx','Vendor-Pricing.xlsx','Audit-Notes.docx','Offer-Letter.pdf']
FOLDERS=['Board Minutes','HR Cases','Client Projects','Tax Returns','Shared With Partners','Planning']
def d(days): return (now-datetime.timedelta(days=days)).strftime('%Y-%m-%d')
def F(site,cat,loc,name,principal,access,days=None,lib='Documents',reach=1):
    root='/'+site.split('.com/')[1]
    link=cat in('AnonymousLink','OrgLink','GuestLink')
    path=root+'/'+lib+('' if loc=='Library' else '/'+name)
    return dict(Site=site,Location=loc,Name=name,CategoryKey=cat,Category=CAT[cat],Access=access,Principal=principal,Path=path,RemovalKind='SharingLink' if link else 'DirectGrant',LinkId='%08x-4c1e'%random.getrandbits(32) if link else None,ListId='b3f1',ItemId=random.randint(3,900),PrincipalId=None if link else random.randint(6,60),LinkCreated=d(days) if link and days else '',RevokeStatus='NotAttempted',Selected=False,Reach=reach)
ANY,ORG='Anyone with the link','People in contoso'
EE='Everyone except external users'
def rnd(site,n):
    out=[];kinds=list(CAT)
    for i in range(n):
        k=kinds[i%5] if i<5 else random.choice(kinds)
        if k in('GuestGrant','EEEU') and random.random()<.5: loc,nm='Library','Documents'
        elif random.random()<.3: loc,nm='Folder',random.choice(FOLDERS)
        else: loc,nm='File',random.choice(FILES)
        pr={'AnonymousLink':ANY,'OrgLink':ORG,'GuestLink':random.choice(['partner@fabrikam.com [guest]','pia@northwind.com [guest]']),'GuestGrant':random.choice(['Alex Guest [guest]','Partner Ltd [guest]']),'EEEU':EE}[k]
        ac=random.choice(['View','Edit']) if k!='EEEU' else 'Read'
        if any(o['CategoryKey']==k and o['Name']==nm for o in out): continue
        out.append(F(site,k,loc,nm,pr,ac,random.randint(5,420),reach=random.choice([1,1,1,240,1800]) if loc!='File' else 1))
    return out
def item(url,title,tpl,st,fl,items,files,mb):
    return dict(Url=url,Title=title,Template=tpl,Status=st,FindingCount=len(fl),ItemsScanned=items,LibrariesScanned=random.randint(2,6) if st!='NotScanned' else 0,FilesScanned=files,StorageMB=mb,Findings=fl)
# Sites: (name,tpl,nfindings|None=notscanned,files,mb)
sites=[('Engineering','Team site',0,39120,912384),('Events2026','Team site',None,0,9340),('Executive-Board','Team site',4,260,3379),('Finance','Team site',9,1940,48230),('HR-Confidential','Team site',7,2810,15410),('Intranet','Communication site',0,310,2164),('IT-Helpdesk','Team site',2,540,1438),('Legal','Team site',0,1130,4268),('Marketing','Communication site',5,8820,182060),('Procurement','Team site',6,2440,19125),('ProjectAtlas','Team site',3,720,2891),('Research','Team site',None,0,88214),('Sales-EMEA','Team site',12,14110,262413)]
S=[]
for nm,tpl,n,fi,mb in sites:
    u='https://contoso.sharepoint.com/sites/'+nm
    if n is None: S.append(item(u,nm,tpl,'NotScanned',[],0,0,mb))
    else: S.append(item(u,nm,tpl,'Clean' if n==0 else 'Findings',rnd(u,n),int(fi*1.15),fi,mb))
# OneDrives
def ou(s): return 'https://contoso-my.sharepoint.com/personal/'+s+'_contoso_com'
ana=ou('ana_silva')
ana_f=[F(ana,'AnonymousLink','File','Customer-List.csv',ANY,'View',212),
F(ana,'OrgLink','File','Payroll-2026.xlsx',ORG,'Edit',38),
F(ana,'GuestLink','File','Contract-Draft.docx','partner@fabrikam.com [guest]','View',96),
F(ana,'AnonymousLink','Folder','Board Minutes',ANY,'Edit',401),
F(ana,'GuestGrant','Folder','Shared With Partners','Alex Guest [guest]','Edit',reach=48),
F(ana,'EEEU','Library','Documents',EE,'Read',reach=2350),
F(ana,'OrgLink','Folder','HR Cases',ORG,'View',17),
F(ana,'GuestLink','File','Vendor-Pricing.xlsx','pia@northwind.com [guest]','Edit',154)]
od=[('ana_silva','Ana Silva','F',5597,ana_f,6800,'','' ),]
rows=[('Ana Silva','ana_silva',None,6420,18734),('Ben Carter','ben_carter',9,1690,3482),('Ella Novak','ella_novak','N',0,214),('Jane Miller','jane_miller','N',0,41203),('Kim Larsen','kim_larsen',3,5778,96512),('Lars Holm','lars_holm',2,2615,7841),('Mia Chen','mia_chen',8,4975,1267),('Noah Weber','noah_weber',0,2087,5638),('Omar Haddad','omar_haddad',0,2094,12046),('Priya Nair','priya_nair',0,494,876),('Sofia Rossi','sofia_rossi',0,1142,2391),('Tom Becker','tom_becker',9,4768,24975)]
O=[]
for t,s,n,fi,mb in rows:
    u=ou(s)
    if n=='N': O.append(item(u,t,'OneDrive','NotScanned',[],0,0,mb))
    elif s=='ana_silva': O.append(item(u,t,'OneDrive','Findings',ana_f,int(fi*1.12),fi,mb))
    else: O.append(item(u,t,'OneDrive','Clean' if n==0 else 'Findings',rnd(u,n),int(fi*1.12),fi,mb))
allc=list(CAT)+['Everyone']
json.dump(dict(Version='1.0',SavedAt=now.isoformat()+'Z',Tabs=[dict(Name='Sites',Categories=allc,Items=S),dict(Name='OneDrives',Categories=allc,Items=O)]),open(sys.argv[2],'w'))

json.dump({"Version":2,"DefaultTenant":"contoso","Tenants":{"contoso":{"AuthMode":"Delegated","ClientId":"00000000-0000-0000-0000-000000000000","Tenant":"contoso.onmicrosoft.com","AdminUrl":"https://contoso-admin.sharepoint.com","Thumbprint":"","CertPath":"","CertExpires":"","IncludeLinkDates":"1"}}},open(sys.argv[1],'w'))
