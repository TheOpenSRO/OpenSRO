# Which source file each function came from

Recovered 2026-09-18 from the `__FILE__` strings the engine's own asserts carry. A
function that hands a path to an assert **is in that file** — this is the binary stating
its own layout, not an inference from the call graph.

`docs/protocol/source_files.tsv` holds the full map: **573 functions**, of which **481 are still unnamed**, across 189 distinct files.

## The original source tree

```
D:\vss-od\Silkroad\Client\client                                243
D:\WORK2005\Source\SilkroadOnline\Server\SR_GameServer           93
D:\Project\SilkroadOnline\TOOLS & PLUGINS\SimpleViewer\objengine   91
D:\vss-od\JMX_Library\navmesh                                    32
D:\WORK2005\Source\JMX_Library\NavMesh_new                       24
D:\WORK2005\Source\SilkroadOnline\Server\ServerCommon            22
d:\project\jmx_library\enginecommon                              11
d:\project\silkroadonline\tools & plugins\simpleviewer\objengine   10
d:\vss-od\jmx_library\gfx\gfxmainframe                            9
D:\vss-od\Silkroad\Client\Landscape\MapEngine                     9
```

Two things worth noticing. The client's object engine sits under a **tools** directory —
`TOOLS & PLUGINS\SimpleViewer\objengine` — so the renderer's object code was shared with
an internal viewer. And there are **two** navmesh libraries, `JMX_Library\navmesh` and
`JMX_Library\NavMesh_new`, which is worth knowing before assuming one navmesh path.

## The biggest files

```
server   GStorage.cpp                        39 functions
client   CharacterDependentData.cpp          23 functions
server   ReferenceData.cpp                   16 functions
client   NetProcessInObject.cpp              16 functions
client   ResObject.cpp                       16 functions
client   MapLoader.cpp                       13 functions
client   CObjCharacter.cpp                   12 functions
server   GStorageOP.cpp                      11 functions
server   MapLoader.cpp                       11 functions
client   IMemory.h                           11 functions
client   GlobalDataManager.cpp               11 functions
client   IEntity.h                            9 functions
```

## Where the map disagrees with the dump's attribution

The dump attributes many functions to a module by call graph, and it says so. Where a
function carries a `__FILE__` path, the path wins. **25 unnamed functions disagree:**

```
client   attributed SWorld                   but its asserts say Map.cpp                      (3)
client   attributed CVBDynamic               but its asserts say VertexBuffer.cpp             (3)
client   attributed CVBStatic                but its asserts say VertexBuffer.cpp             (3)
client   attributed UI_ALCHEMYBOX            but its asserts say DropItemManager.cpp          (2)
client   attributed G                        but its asserts say IndexBuffer.h                (2)
server   attributed RefMagicOptByItemOptLevel but its asserts say ReferenceData.cpp            (1)
client   attributed CNIFDragableArea         but its asserts say NIFDraggableArea.cpp         (1)
client   attributed UI_SILKMALL              but its asserts say IFRenderStatic.cpp           (1)
client   attributed UI_SILKMALL              but its asserts say IFNewItemMall.cpp            (1)
client   attributed SWorld                   but its asserts say DynamicShadow.cpp            (1)
client   attributed CWRain                   but its asserts say IEntity.h                    (1)
client   attributed CWRainWave               but its asserts say IEntity.h                    (1)
```

`CNIFDragableArea` against `NIFDraggableArea.cpp` is not a disagreement worth fixing —
the class name and the file name simply spell *draggable* differently, and both are the
binary's own.

## What this is for

It is attribution, not naming: no function is named here. Its use is targeting — a
question like *where is the drop logic* now has an address list instead of a guess, and a
future pass that names one function in a file knows which other functions share it.
