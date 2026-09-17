import sys, re, collections
sys.path.insert(0,"/var/tmp"); import rebox as X
for dump,label in ((X.SRV,"server"),(X.CLI,"client")):
    fs=X.funcs(dump)
    named=[f for f in fs if not X.unnamed(f["name"])]
    crt=[f for f in fs if f["addr"]>=0x900000]
    game=[f for f in fs if f["addr"]<0x900000]
    gnamed=[f for f in game if not X.unnamed(f["name"])]
    print("%s: %d functions, %d named (%.1f%%)" % (label,len(fs),len(named),100*len(named)/len(fs)))
    print("   below 0x900000 (game logic): %d, named %d (%.1f%%)" %
          (len(game),len(gnamed),100*len(gnamed)/len(game)))
    print("   at/above 0x900000 (CRT etc): %d, named %d" % (len(crt),len([f for f in crt if not X.unnamed(f["name"])])))
    # biggest unnamed functions still outstanding
    un=sorted((f for f in game if X.unnamed(f["name"])), key=lambda f:-f["size"])[:8]
    print("   largest unnamed game functions:")
    for f in un: print("      %08x size=%-6d %s" % (f["addr"],f["size"],f["name"][:50]))
    print()
