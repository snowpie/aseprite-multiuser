# Local Multiplayer Plugin for Aseprite

The local multiplayer plugin for Aseprite allows you to connect two PCs on a local network to work together on animations or multi-layer artwork.  
During installation, allow the plugin to use its internal folder.  
Extension function is in **File → Multiplayer**.

## Multiplayer Sync Setup

1. **My IP**: Shows your local IP address.  
2. **IP to sync**: Enter the **My IP** from the computer you want to connect with, and vice versa.  
3. **PORT to sync**: The port through which the computers will communicate. Unless you are using another application on this port, you can leave the default 5000.  
4. **Interval of sync**: Enter how often the data should be synchronized.  
5. **Sync Tab**: Select the sprite tab that you want to synchronize.  

After setting all the parameters, you can enable synchronization on both computers using the **Turn sync ON** button. If any error occurs, make sure **IP to sync** and **Sync Tab** are correctly set, then press **Clear server files** and try again.

After successful synchronization, you will see two new windows:  

### Server Window
This window will show something like this:  

```
Plugin folder: C:\Users\User\AppData\Roaming\Aseprite\extensions\asemultiplayer-plugin
Command file: C:\Users\User\AppData\Roaming\Aseprite\extensions\asemultiplayer-plugin\command.txt
P2P server listening on port 5000, peer 192.168.x.y
```
Do not close this window. It is going to show server commands, send and recived cels and other network related information.

### Aseprite SYNC Window aka SYNC Detector
Aseprite window with the title `SYNC (closing me will stop sync)`.  
The title is not a joke, this window monitors synchronization, and closing it will stop the sync. Close it only when you finish collaborative work.

This window is used to monitor synchronization.

1. **Tab**: Shows whether the current tab is the one being synchronized.  
2. **My Layer**: Shows your current layer.  
3. **My Frame**: Shows your current frame.  
4. **Peer Layer**: Shows the layer of your collaborator.  
5. **Peer Frame**: Shows the frame of your collaborator.  

The **Push** and **Pull** buttons are used to manually send or receive data if needed.  

Below these buttons, the extension displays potential conflicts in the project with your collaborator.

## Suggested Workflow
The extension automatically sends and receives data at the set interval and whenever the frame or layer changes.  
To reduce data transfer, frames are sent only if they have been modified.  
If both collaborators are on the same layer and frame (which the SYNC detector will indicate with a message and three exclamation marks **!!!**), changes will not be sent unless the **Push** button is used.  
This extension was primarily designed for collaborative animation work, so collaborators usually do not interfere with each other because they work on separate frames.

## Additional Information
This extension was developed for personal use and may not be perfect. If you encounter any issues or have questions, feel free to reach out via email at **zamylosz@gmail.com**.
