# Game Engine Technical Description

## Rendering

### Basic description

Rendering voxel world, entities and visual effects on GPU.

### Implemetation details

Renders voxel world, voxel meshes and ligth sources.

**Rendering alghoritm**  
Raycasting optimised for voxel rendering.

**Raycaster effects**
- shadows
- reflection
- transparency
- ligth emiting voxels

### Optimisations

## World

### Basic description

**Universe**
list of worlds.
**World**
world data such as name, id, etc. and grid of chunks.
**Chunk**
16x16x16 grid of blocks.
**Block**
16x16x16 grid of voxels.

### Implemetation details

### Optimisations

## Events

### Basic description

Decoupling system. Systems send events to event queue instead of calling systems directly. Allowing greater flexibility and modularity of code.

### Implemetation details

**Event**
Message system can send into event system and it'll execute function asociated with it on event loop or system subscribed to that types queue will process.

**Event type**
Event type is like category for event. It'll be writen into queue based on event type. Each type has it's own queue. It also can have different behaviours when full etc.

**Event Queue**
Simple fifo structure that accepts events and will return them in order they came in. In future i'll maybe add prio to events. But not for now.

**Event system**
Big structure containing queue for each event type. It'll recieve events and write them to queue based on type. It'll also be responsible for event loop thread that will execute event types without other system subscribed to it.

### Optimisations

## Entities

### Basic description

System handling entities. There will be multiple types of entities. 
**Physical objects**
simplest, voxel mesh that is not aligned with world grid, can be shifted and rotated in any way. Is effected by gravity. Colides with other physical objects and world.
**Preprogramed entity**
Entity witch path can be set. Doors, etc.
**AI entity**
most complex type, has path finding, goals, moves through world and acts based on based on it's behavior system.

### Implemetation details

### Optimisations

## Physics System

### Basic description

System handling physics simulations like entity physics. Heat, electricity and other systems in future.

### Implemetation details

### Optimisations

## UI System

### Basic description

All menus, inventories, etc. Basicaly library to create grapical UI that will share style across game.

### Implemetation details

### Optimisations

## Input System

### Basic description

Reading inputs and sending rigth events based on games state. Differnet events in inventory, in game, combat, etc.

### Implemetation details

### Optimisations

## Inventory System

### Basic description

System handling items. Inventory.

### Implemetation details

### Optimisations

## Game State System

### Basic description

System holding more global game state.

### Implemetation details

### Optimisations

