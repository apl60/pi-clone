# Description:  A CLI tool to clone a running Raspberry Pi OS (Bookworm) 
#               to a USB or SD device with optional data partitioning.

I have been testing quite some solutions, including the once provided by rasbian 
but running into all kind off issues, I decided to create my own version.
After some trial and error, it works now fine (at least for me)
The clonig focusses primarily on the boot and root partition, assuming that you have 
a good backup for your data (partition), which is in my case an IOTstack, residing on
a dedicated data partition.
The script allows to clone also the data partition, if the target device (an USB key or 
another sd-card via an USB adapter has enouph capacity availabe.
