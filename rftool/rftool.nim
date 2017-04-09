#
# (C) Panagiotis Karagiannis 
# This file is part of rfboot
# https://github.com/pkarsy/rfboot
# Licence GPLv3
#

import strutils
import os
import osproc
import times
import posix

# This is the size of rfboot in atmega FLASH
const BOOTLOADER_SIZE = 4096

{.compile: "serial.c".}
proc c_openport*(port: cstring):cint {.importc.}
proc readser*(fd: cint, buf: cstring, nbytes: cint, timeout: cint): cint {.importc.}
proc writeser(fd: cint, buf: cstring, nbytes: cint) {.importc.}
proc c_getchar(fd: cint, timeout: cint): cint {.importc.}


const RFB_NO_SIGNATURE = 1
const RFB_INVALID_CODE_SIZE = 2
# const RFB_ROUND_IS = 3 Not used anymore in the code
const RFB_SEND_PKT = 4
const RFB_WRONG_CRC=5
const RFB_SUCCESS=6

const ApplicationSettingsFile = "app_settings.h"
const RfbootSettingsFile = "rfboot/rfboot_settings.h"
const MaxAppSize = 32*1024 - BOOTLOADER_SIZE
const StartSignature = 0xd20f6cdf # This is expected from rfboot
const Payload = 32 # The same as rfboot
const CommdModeStr = "COMMD" # This word, switches the usb2rf module to command mode
const RandomGen = "/dev/urandom"
const homeconfig = "~/.usb2rf"
const serialPortDir = "/dev/serial/by-id"

# This holds the PID of Serial Terminal software, if one has opened the serial port
# of the usb2rf module
var LPID: int

# packs a uint16 in 2 bytes, little endian
proc toString(u: uint16): string =
  return char(u and 0xff) & char(u shr 8)

# packs a uint32 in 4 bytes, little endian
proc toString(u: uint32): string =
  return (u and 0xffff).uint16.toString & (u shr 16).uint16.toString


# This code is from AVR gcc documentation avr/crc.h
# converted with c2nim, and corrected by hand
# There seems to be a lot of crc algorithms floating around. However
# as the other end (rfboot) is going to use this algorithm, (or the equivalent in asm)
# we must use the same
proc crc16_update(crc: var uint16, a: uint8) =
  crc = crc xor a
  for i in 0 .. 7:
    if (crc and 1) == 1:
      crc = (crc shr 1) xor 0xA001
    else:
      crc = (crc shr 1)

# calculates the crc16 for a string using the crc16_update proc (see above)
proc crc16(buf: string): uint16 =
  #result is initialized with 0
  for i,c in buf:
    crc16_update(result,c.uint8)
  #returns the result variable


# The same as above but with the reversed string. We use 2 crcs in order to
# achieve (MUCH) better error detection. I tried to use a crc32 function
# but then the size of rfboot (on the atmega side) becomes too large
# EDIT: it seems it should be viable to use CRC32, but for protocol
# compatibility we leave it as is. It is working OK anyway
proc crc16_rev(buf: string): uint16 =
  for i,c in buf:
    crc16_update(result,buf[buf.high-i].uint8)

proc parseKey(keyStr: string): array[4,uint32] =
  const msg = "XteaKey: Expecting 4 integers (0 to 4294967295) separated by comma"
  let key = keyStr.toLowerAscii.replace("u","").replace(" ","").split(",")
  if key.len != 4:
    stderr.writeLine msg
    quit QuitFailure
  try:
    for i,k in key:
      # parseBiggestInt is needed for 32bit systems
      let intval = k.replace('u',' ').replace('U',' ').strip().parseBiggestInt
      if intval>=0 and intval<=4294967295:
        result[i]=intval.uint32
      else:
        stderr.writeLine msg
        quit QuitFailure
  except ValueError, OverflowError:
    stderr.writeLine "Value or overflow error while parsing KEY: ", keyStr
    quit QuitFailure

# This proc comes form the wikipedia article about xtea. again converted with
# c2nim amd modified by hand
# Note that this one, instead of modifying the input, returns the encrypted result
# xtea works with 8 byte  blocks, and treats them as 2 uint32 numbers
proc xteaEncipher(v: array[2, uint32]; key: array[4, uint32]) : array[2, uint32] =

  const delta: uint32 = 0x9E3779B9'u32
  const num_rounds = 32
  var
    v0 = v[0]
    v1 = v[1]
    sum: uint32 = 0
  for round in countup(1, num_rounds):
    v0 += (((v1 shl 4) xor (v1 shr 5)) + v1) xor (sum + key[sum.int and 3])
    sum += delta
    v1 += (((v0 shl 4) xor (v0 shr 5)) + v0) xor (sum + key[(sum shr 11).int and 3])
  return [v0,v1]

# for use with "echo"
proc `$`(a:array[2, uint32]): string =
  return "{" & $a[0] & "," & $a[1] & "}"

# TODO I tested with some python XTEA-implementations and it is OK
proc xteaEncipherCbc(v: array[2, uint32]; key: array[4, uint32], iv: var array[2,uint32]) : array[2, uint32] =
  result = xteaEncipher([v[0] xor iv[0],v[1] xor iv[1]] ,key)
  iv = result


# xtea encrypt a string. The string is treated as a series of little endian
# uint32 numbers. The string must have a size multiple of 8
# [ BYTE0(LSB) BYTE1 BYTE2 BYTE3(MSB) ] -> uint32
# ie "1000" -> 1'u32
proc xteaEncipherCbc(st: string, key: array[4,uint32], iv: var array[2,uint32] ) : string =
  result = ""
  assert(st.len mod 8 == 0,"String to be encrypted must have size multiple of 8 bytes")
  for i in countup(0 , st.len - 1, step=8):
    var x0,x1:uint32
    let s = st[i .. i+7]
    for i in countdown(3,1):
      x0+=s[i].uint32
      x0 = x0 shl 8
    x0 += s[0].uint32
    for i in countdown(7,5):
      x1+=s[i].uint32
      x1 = x1 shl 8
    x1 += s[4].uint32

    block:
      let x = xteaEncipherCbc([x0,x1],key,iv)
      x0=x[0]
      x1=x[1]
    var pkt = "00000000"
    for i in 0..2:
      pkt[i]=char(x0 and 0xff)
      x0 = x0 shr 8
    pkt[3]=char(x0)
    for i in 4..6:
      pkt[i]=char(x1 and 0xff)
      x1 = x1 shr 8
    pkt[7]=char(x1)
    result.add pkt

proc getKnownPorts() : seq[string] =
  result = @[]
  if not homeconfig.expandTilde.existsFile:
    stderr.writeLine "failed to open file \"", homeconfig, "\", creating an empty one."
    #" rftool uses it to get the serial port device name."
    var f = homeconfig.expandTilde.open(mode=fmWrite)
    f.writeLine "# serial ports that rftool regards as usb2rf modules"
    f.close
    return
  var f: File
  try:
    f = homeconfig.expandTilde.open
  except IOError:
    stderr.writeLine "failed to open file \"", homeconfig, "\""
    #return
    quit QuitFailure
  while true:
    var s: string
    try:
      s = f.readLine.strip
    except IOError:
      #break
      f.close
      return
    if s=="" or s.startsWith("#") or s.startsWith("//") or s.startsWith("!"):
      discard
    elif not s.startsWith("/dev/"):
      discard
    else:
      result.add(s)


proc getConnectedPorts() : seq[string] =
  result = @[]
  for e in walkDir(serialPortDir):
    if e.kind == pcLinkToFile:
      result.add(e.path)


proc getPortName() : string =
  var hwID: string
  var f: File
  
  try:
    f = homeconfig.expandTilde.open
  except IOError:
    stderr.writeLine "failed to open file \"", homeconfig, "\". rftool uses it to get the serial port device name."
    quit QuitFailure

  while true:
    var s: string
    try:
      s = f.readLine.strip
      #echo "line=",s
    except IOError:
      break
    if s=="" or s.startsWith("#") or s.startsWith("//") or s.startsWith("!"):
      discard
    elif not s.startsWith("/dev/"):
      #stderr.writeLine(""
      discard
    elif not ( fileExists(s) or symlinkExists(s) ):
      #stderr.writeLine "Device ",s," is not connected"
      discard
    else:
      hwID = s
      break
  if hwID==nil:
    stderr.writeLine "Config file does not point to any connected device"
    quit QuitFailure
  var portName = $realpath(hwID,nil)
  #stderr.writeLine "port = ",portName
  # This is used by the sendStopSignal() sendContSignal()
  #portName = hwID
  return portName


proc checkLockFile(portName:string): int =
  let port = splitPath(portName)[1]
  let lockfile = "/var/lock/LCK.." & port
  if existsFile(lockfile):
    echo "lockfile found : \"",lockfile,"\""
    let info = lockfile.readFile.strip.split
    let pid = info[0].parseInt
    #echo "pid=",pid
    #echo "/proc/xxx=", "/proc/" & info[0]
    if existsDir( "/proc/" & info[0]):
      return pid
    else:
      stderr.writeLine("Lockfile is stale")
      discard unlink(lockfile)
      return -1
  else:
    return -1


# Stops other processess accessing the serial port
# is used for code upload even with an open terminal (usually gtkterm)
proc sendStopSignal(portname:string): bool =
  #discard execProcess( "/bin/fuser", ["-s", "-k", "-STOP", portName] , options={ poStdErrToStdOut })
  LPID = checkLockFile(portname)
  if (LPID>0):
    discard kill(LPID,SIGSTOP)
    stderr.writeLine "Stop PID:",LPID," thad holds a LOCK on the serial port"
    return true
  else:
    return false


# resumes the processes being stopped
# see the previous function
proc sendContSignal() {.noconv.} =
  #discard execProcess( "/bin/fuser", ["-s", "-k", "-CONT", portName], options={ poStdErrToStdOut } )
  if (LPID)>0:
    stderr.writeLine "Send a CONT signal to PID:", LPID
    discard kill(LPID, SIGCONT)
  

proc openPort(portname: cstring): cint =
    if sendStopSignal($portname):
      addQuitProc sendContSignal
    result = c_openport(portname)
    if result<0 :
      stderr.writeLine "Cannot open serial port \"", portName, "\" . Error=", result
      quit QuitFailure


# a random integer 0-255
proc rand(): int =
  let randFile = open(RandomGen)
  result = randFile.readChar.int
  randFile.close



discard """proc randomChannel(): int =
  const channels = 79 # random 0..78 we add 1 -> 1..79
  const maxRan = (256 div channels)*channels
  while true:
      let r=rand()
      if r<maxRan:
        #echo "good r = ",r
        return (r mod channels)+1"""


proc randomUint32(): uint32 =
  # we fill the uint32 bytes with random data
  let randFile = open(RandomGen)
  discard readBuffer(randFile,addr result,4)
  randFile.close


proc randomXteaKey(): array[4,uint32] =
  for i in 0..3:
    result[i]=randomUint32()


proc randomString(n: Natural): string =
  let randFile = open(RandomGen)
  result=""
  for i in 1..n:
    result.add randFile.readChar()
  randFile.close


proc keyAsArrayC(key: array[4,uint32]): string =
  return "{ " & $key[0] & "u , " & $key[1] & "u , " & $key[2] & "u , " & $key[3] & "u }"


proc getUploadParams() : tuple[ rfbChannel:int, rfbootAddress:string, key: array[4,uint32] ] =
  var rfbootConf : string
  try:
     rfbootConf = readFile(RfbootSettingsFile)
  except IOError:
    stderr.writeLine "The file \"", RfbootSettingsFile, "\" does not exist."
    quit QuitFailure
  for i in rfbootConf.splitLines:
    var line = i.strip()
    if (line.len > 0) and not (line[0] in "/"):
      if line.contains("XTEAKEY"):
        let brstart = line.find('{')
        let brend = line.find('}')
        line = line[brstart+1..brend-1]
        result.key = parseKey(line)
      elif line.contains("RFBOOT_ADDRESS"):
        let qnumber = line.count('\"')
        if qnumber != 2:
          stderr.writeLine "In file \"", RfbootSettingsFile, "\", the RFBOOT_ADDRESS line has ", qnumber, " \". Expected 2, enclosing the RF address"
          quit QuitFailure
        let startl = line.find('\"')
        let endl = line.rfind('\"')
        result.rfbootAddress = line[startl+1..endl-1]
        stderr.writeLine "rfboot_address=",result.rfbootAddress
      elif line.contains("RFBOOT_CHANNEL"):
        if line.count('=') != 1:
          stderr.writeLine "In file \"", RfbootSettingsFile, "\", the RF_CHANNEL line is missing a \"=\""
        let startl = line.find('=')
        let endl = line.find ';'
        if endl == -1:
          stderr.writeLine "In file \"", RfbootSettingsFile, "\", the RF_CHANNEL line is missing a \";\" at the end"
          quit QuitFailure
        line = line[startl+1 .. endl-1].strip
        if line.len==0 or not line.isDigit:  #  or line.len>3 or line.parseInt>127
          echo '"',line,'"'
          stderr.writeLine "In file \"", RfbootSettingsFile, "\", the RF_CHANNEL must be an integer"
          quit QuitFailure
        result.rfbChannel = line.parseInt
      if line.contains("RFB_SYNCWORD"):
        let brstart = line.find('{')
        let brend = line.find('}')
        line = line[brstart+1..brend-1]
        var sw = "  "
        for i in 0..1:
          sw[i] = line.split(',')[i].strip.parseInt.char
        result.rfbootAddress = sw


proc toArray(s:string): string =
  result = "{"
  for i,c in s:
    result &= $c.int
    if i<s.len-1:
      result &= ","
  result &= "}"


proc getAppParams() : tuple[appChannel:int, appAddress:string, resetString: string] =
  var conf: string
  try:
    conf = readFile ApplicationSettingsFile
  except IOError:
    stderr.writeLine "File \"",  ApplicationSettingsFile, "\" does not exist."
    quit QuitFailure
  for i in conf.splitLines:
    var line = i.strip()
    if (line.len > 0) and not (line[0] in "/"):
      if line.contains("APP_ADDRESS"):
        let qnumber = line.count('\"')
        if qnumber != 2:
          stderr.writeLine "In file \"", ApplicationSettingsFile, "\", the APP_ADDRESS line has ", qnumber, " \". Expected 2, enclosing the RF address"
          quit QuitFailure
        let startl = line.find('\"')
        let endl = line.rfind('\"')
        result.appAddress = line[startl+1..endl-1]
        stderr.writeLine "appAddress=", result.appAddress.toArray
      elif line.contains("RESET_STRING"):
        let qnumber = line.count('\"')
        if qnumber != 2:
          stderr.writeLine "In file \"", ApplicationSettingsFile, "\", the RESET_STRING line has ", qnumber, " \". Expected 2, enclosing the string"
          quit QuitFailure
        let startl = line.find('\"')
        let endl = line.rfind('\"')
        if endl-startl==1:
          stderr.writeLine "In file \"", ApplicationSettingsFile, "\", the RESET_STRING cannot be empty"
          quit QuitFailure
        result.resetString = line[startl+1..endl-1]
        stderr.writeLine "resetString=",result.resetString
      elif line.contains("APP_CHANNEL"):
        if line.count('=') != 1:
          stderr.writeLine "In file \"", ApplicationSettingsFile, "\", the APP_CHANNEL line is missing a \"=\""
        let startl = line.find('=')
        let endl = line.find ';'
        if endl == -1:
          stderr.writeLine "In file \"", ApplicationSettingsFile, "\", the APP_CHANNEL line is missing a \";\" at the end"
          quit QuitFailure
        line = line[startl+1 .. endl-1].strip
        if line.len==0 or not line.isDigit : # or line.len>3 or line.parseInt>127
          echo '"',line,'"'
          stderr.writeLine "In file \"", ApplicationSettingsFile, "\", the APP_CHANNEL must be an integer"
          quit QuitFailure
        result.appChannel = line.parseInt
      elif line.contains("APP_SYNCWORD[]"):
        let brstart = line.find('{')
        let brend = line.find('}')
        line = line[brstart+1..brend-1]
        var sw = "  "
        for i in 0..1:
          sw[i] = line.split(',')[i].strip.parseInt.char
        result.appAddress = sw


proc getApp(fn : string): string =
  var app:string
  block:
    var f = fn.open
    var fsize = f.getFileSize
    if fsize<2:
      stderr.writeLine "Provided file is only ", fsize, " bytes"
      quit QuitFailure
    elif fsize>MaxAppSize:
      stderr.writeLine "Very big application code size : ",fsize," bytes"
      quit QuitFailure
    elif (fsize mod 2) == 1:
      stderr.writeLine "File size must be multiple of 2"
      quit QuitFailure
    app = $f.readAll
    f.close
  if app[0..1]=="\xff\xff":
    stderr.writeLine "The binary of the application cannot start with 0xffff"
    stderr.writeLine "This file cannot be an AVR binary(opcodes) file"
    quit QuitFailure
  return app


proc write( port: cint, data: string) =
  var buf: char
  for c in data:
    buf = c
    writeser(port, addr buf, 1)


proc getChar(port: cint, timeout: cint = 100000): int =
  let n = c_getchar(port, timeout)
  return n


proc drain(port: cint, timeout: cint=100000) {.noconv.} =
  while port.getChar(timeout) != -1:
    discard


proc getPacket(port: cint, timeout: cint = 100000, size:int = 1000000): string = #tuple[ sender: MessageOrigin, text: string] =
  var sz = size;
  while (sz>0):
    let res = port.getChar(timeout)
    if res == -1:
      return
    else:
      if result == nil: result = ""
      result.add res.char
    sz-=1


proc setChannel(port: cint, channel: 0..127) =
  port.write CommdModeStr & "C" & channel.char
  port.drain 10000


proc setAddress(port: cint, address: string) =
  port.write CommdModeStr & "A" & address
  port.drain 10000


proc actionCreate() =
  const SkelDir = "skel"
  const RfbDir = "rfboot"
  let fileSource = splitPath(splitPath(getAppFilename())[0])[0] & DirSep
  for d in [RfbDir, SkelDir]:
    if not existsDir(fileSource & d):
      stderr.writeLine "The root folder of rfboot \"", fileSource, "\" does not contain the \"", d ,"\" folder"
      stderr.writeLine "The rfboot software is not installed corrrectly."
      stderr.writeLine "See https://github.com/pkarsy/rfboot/wiki/Installation"
      quit QuitFailure
  var p = commandLineParams()
  if p.len<2:
    stderr.writeLine "Project name not given"
    quit QuitFailure
  let projectName = p[1].strip
  if projectName.len==0:
    stderr.writeLine "Project name not given"
    quit QuitFailure
  elif existsDir(projectName) or existsFile(projectName) or symlinkExists(projectName):
    stderr.writeLine "\"", projectName , "\" already exists"
    quit QuitFailure
  elif not projectName.isAlphaNumeric:
    stderr.writeLine "Only alphanumeric characters should be used in project name"
    quit QuitFailure
  # TODO
  # Channel random ?
  var appChannel = 1
  var xteaKey = randomXteaKey()
  var appSyncWord0 = rand()
  var appSyncWord1 = rand()
  var rfbSyncWord0 = rand()
  var rfbSyncWord1 = rand()
  var rfbChannel = 4
  discard """
  var options_table = initTable[string,string]()
  for i in countup(2,p.len-1,step=2):
    var key = p[i]
    if key[0] != '-':
      stderr.writeLine "Οptions must start with '-'"
      quit QuitFailure
    var val: string
    if i+1<p.len:
      val = p[i+1]
    if val==nil or val=="" :
      stderr.writeLine "Option \"", key, "\" without a value"
      quit QuitFailure
    else:
      key = key.strip(leading=true,trailing=false,chars = {'-'}).normalize
      options_table[key]=val
  for key,val in options_table:
      case key:
      #of "n","name", "projectname":
      #  if val.len == 0:
      #    quit "The name of the project cannot be empty"
      #  elif not val.isAlphaNumeric:
      #    quit "Only alphanumeric characters should be used in project name"
      #  else:
      #    p.projectName = val


      of "c", "channel":
        #TODO alla channel gia to cc1101
        const msg="Channel option needs an integer 0-127"
        if val=="":
          stderr.writeLine msg
          quit QuitFailure
        else:
          try:
            channel = parseInt(val)
          except ValueError:
            stderr.writeLine msg
            quit QuitFailure
          if 0<= channel and channel <= 127:
            discard
          else:
            stderr.writeLine msg
            quit QuitFailure
      of "key":
        xteaKey = val.parseKey

      else:
        stderr.write "Unknown option/argument : ", key, "\n"
        quit QuitFailure

      #    elif not val.isAlphaNumeric:
      #quit "Only alphanumeric characters should be used in project name"
      """
  copyDir(fileSource & SkelDir, projectName)
  setCurrentDir(projectName)
  moveFile("skel.ino",projectName & ".ino")
  for f in walkDirs("build-*"):
    removeDir(f)
  copyDir(fileSource & RfbDir, RfbDir)
  block:
    let f = open(ApplicationSettingsFile, fmWrite)
    f.writeLine "// This file :"
    f.writeLine "// - Is used by the Arduino .ino file to get RF settings"
    f.writeLine "// - Is parsed at runtime by rftool to get app parameters (channel etc)"
    #f.writeLine "// to send the application the reset word"
    f.writeLine ""
    f.writeLine "// These parameters are generated with"
    f.writeLine "// \"rftool create ", projectName, "\""
    f.writeLine "// The values of APP_SYNCWORD and APP_CHANNEL"
    f.writeLine "// are randomly generated with the system randomness generator"
    f.writeLine "// \"/dev/urandom\""
    f.writeLine ""
    f.writeLine "const uint8_t APP_CHANNEL = ", appChannel, ";"
    f.writeLine "const uint8_t APP_SYNCWORD[] = {", appSyncWord0, ",", appSyncWord1, "};"
    f.writeLine "const char RESET_STRING[] = \"RST_", projectName, "\";"
    f.close
  block:
    let f = open(RfbootSettingsFile, fmWrite)
    f.writeLine "// XTEAKEY RFB_SYNCWORD APP_ADDRESS and RFBOOT_CHANNEL are randomly"
    f.writeLine "// generated with the system randomness generator /dev/urandom"
    f.writeLine "// After the bootloader is installed to the target module, you cannot"
    f.writeLine "// change the parameters, otherwise, the upload process will fail"
    f.writeLine ""
    f.writeLine "const uint8_t RFBOOT_CHANNEL = ", rfbChannel, ";"
    f.writeLine "const uint8_t RFB_SYNCWORD[] = {", rfbSyncWord0,",", rfbSyncWord1, "};"
    f.writeLine "// This key is only used when updating firmware. The application code does not use it"
    #f.writeLine "// Note also that there is no any guarantee that the encryption offers any confidenciality"
    f.writeLine "const uint32_t XTEAKEY[] = ", xteaKey.keyAsArrayC, ";"
    discard """
// If uncommented,  does not allow code to be uploaded, unless the reset button is pressed
// Can be useful if the project has stable firmware but there is need for some
// rare updades. Also if we do not want updates without physical contact
//#define UPLOAD_AT_HW_RESET_ONLY

// There may be cases we want the bootloader disabled unless a jumper is connected.
// Rfboot sets the pin as INPUT with PULLUP enabled. At boot rfboot checks
// the state of the PIN, and if it is LOW then rfboot enables the RF and waits for code
// Not implemented yet
// only 1 is accepted as true
//#define ENABLE_AT_LOW_PIN_ONLY
//#define ENABLE_PIN B,0
"""
    f.close
  block:
    #echo "Project Name = ", projectName
    echo "Application SyncWord = ", appSyncWord0, ",", appSyncWord1
    echo "rfboot SyncWord = ", rfbSyncWord0, ",", rfbSyncWord1
    echo "rfboot channel = ", rfbChannel
    echo "Application channel = ", appChannel


proc actionUpload(binaryFileName: string, timeout=10.0) =
  var lastbinarysize:Off
  block:
    var s:Stat
    var statres = stat(".lastbinary", s)
    if statres==0:
      lastbinarysize = s.st_size
      #echo "lastbinary size = ", s.st_size
  var app = getApp(binaryFileName)
  if app.len == lastbinarysize:
    let lastapp = open(".lastbinary").readAll
    #echo lastapp.len
    if app == lastapp:
      echo "The new firmware is identical to the last one. No need for upload"
      quit QuitSuccess

  # Pad the app with 0xFF to multiple of Payload
  block:
    let modulo = app.len mod Payload
    if modulo != 0:
      app.add '\xff'.repeat(Payload-modulo)

  let (rfbChannel,rfbAddress,key) = getUploadParams()
  let (newAppChannel, newAppAddress, newResetString) = getAppParams()
  var appChannel: int
  var appAddress = "12"
  var resetString: string
  #var round: int
  try:
    let lastupload = open(".lastupload", fmRead)
    appChannel= lastupload.readline.strip.parseInt
    appAddress[0] = lastupload.readline.strip.parseInt.char
    appAddress[1] = lastupload.readline.strip.parseInt.char
    resetString = lastupload.readline.strip
    lastupload.close
  except IOError:
    appChannel = newAppChannel
    appAddress = newAppAddress
    resetString = newResetString
  if resetString!=nil or resetString!="":
    if newAppChannel!=appChannel:
      stderr.writeLine "WARNING : appChannel changed to ", newAppChannel, ". Using the old ", appChannel, " to send the reset signal"
    if newAppAddress != appAddress:
      stderr.writeLine "WARNING : appAddress changed to ", newAppAddress.toArray, ". Using the old ", appAddress.toArray, " to send the reset signal"
    if newResetString != resetString:
      stderr.writeLine "WARNING : resetString changed to ", newResetString, ". Using the old ", resetString, " to send the reset signal"
  let portname = getPortName()
  let port = portname.openPort()

  var header = StartSignature.uint32.toString & app.len.uint16.toString &
    app.crc16.toString & app.crc16_rev.toString & 0.uint16.toString &
    StartSignature.uint32.toString & randomString(16)

  var smallHeader = StartSignature.uint32.toString
  port.drain(5000)
  port.write(CommdModeStr & "Z")  # fast reset
  const USB2RF_START_MESSAGE = "USB2RF"
  let p = port.getPacket(200000, len(USB2RF_START_MESSAGE) )
  if p!=USB2RF_START_MESSAGE:
    stderr.writeLine "Cannot contact usb2rf"
    quit QuitFailure
  else:
    stderr.writeLine "module identified : \"", USB2RF_START_MESSAGE, "\""
  if resetString==nil or resetString=="":
    stderr.writeLine "Contacting rfboot. Reset the module ..."
    stderr.writeLine "The process will continue to try for ", timeout , " sec"
  else:
    stderr.writeLine "App channel = ", appChannel
    port.setChannel appChannel
    stderr.writeLine "App address = ", appAddress.toArray
    port.setAddress appAddress
    stderr.writeLine "Reset String = ", resetString
    port.write resetString
    # TODO na psaxnei mesa se ena string
    let msg = port.getPacket(100000, resetString.len)
    if msg == resetString:
      stderr.writeLine "Ok the target reported reset"
    else:
      stderr.writeLine "Target did not answer the reset command, trying to send code anyway"
  stderr.writeLine "rfboot address = ", rfbAddress.toArray
  port.setAddress rfbAddress
  stderr.writeLine "rfboot channel = ", rfbChannel
  port.setChannel rfbChannel
  port.drain(5000)
  var contact = false
  var msg: string
  var iv: array[2,uint32];
  var startPingTime = epochTime()
  while epochTime() - startPingTime < timeout:
    port.write smallHeader
    msg = port.getPacket(100000,8)
    if msg!=nil:
      contact = true
      break
  if not contact:
    stderr.writeLine("Cannot contact rfboot")
    port.setChannel appChannel
    port.setAddress appAddress
    port.drain 2000
    quit QuitFailure
  else:
    if msg.len == 8:
      iv[0]=msg[0].uint32+msg[1].uint32*256+msg[2].uint32*256*256+msg[3].uint32*256*256*256
      iv[1]=msg[4].uint32+msg[5].uint32*256+msg[6].uint32*256*256+msg[7].uint32*256*256*256
      stderr.writeLine "IV=", iv
      #let ivdecrypted=xtea_decipher(iv);
      #TODO
      # if msg.len==9 neos rfboot thelei CRC 32+1 byte
      #TODO
    else:
      stderr.writeLine "Wrong IV length from rfboot", msg.len
      quit QuitFailure
  header = xteaEncipherCbc(header, key, iv)
  block:
    var app1=""
    var i = app.len
    # TODO den xreiazetai na to kanei prokatavolika
    while i>0:
      app1 = xteaEncipherCbc(app[i-32..i-1], key, iv) & app1
      i-=32
    app = app1
  # Sending the header
  if header.len != Payload:
    stderr.writeLine "Internal error, packet is not ", Payload, " bytes long"
    quit QuitFailure

  startPingTime = epochTime()
  while epochTime() - startPingTime < timeout:
    port.write header
    msg = port.getPacket(100000,3)
    if msg!=nil:
      contact = true
      break
  if not contact:
    stderr.writeLine("Cannot contact rfboot")
    quit QuitFailure
  if msg.len != 3:
    stderr.writeLine "Invalid message from rfboot. len=", msg.len
    for i in msg:
      stderr.writeLine i.int
    quit QuitFailure
  let reply = msg[0].int
  let data = msg[1].int + 256 * msg[2].int
  var startUploadTime: float
  if reply == RFB_NO_SIGNATURE:
    stderr.writeLine "rfboot reports wrong signature"
    quit QuitFailure
  elif reply == RFB_INVALID_CODE_SIZE:
    stderr.writeLine "rfboot reports that application size is invalid"
    quit QuitFailure
  elif reply == RFB_SEND_PKT:
    startUploadTime = epochTime()
  else:
    stderr.writeLine "Unknown response ", reply, " data=", data
    quit QuitFailure
  var pkt_idx = data
  var pkt_idx_prev=pkt_idx

  const upload_method = 1
  ################################## METHOD 0 (The old) ##############################
  if upload_method==0:
    while pkt_idx >= PAYLOAD:
      port.write app[pkt_idx-32..pkt_idx-1]
      var res: string
      if (pkt_idx==PAYLOAD):
        #perimenoume parapano giati mporei na argisei na apantisei logo tou CRC check
        res = port.getPacket(1200000,3)
        if res == nil:
          stderr.writeLine "After sending the last packet got no reply"
          quit QuitFailure
        elif res.len != 3:
          stderr.writeLine "Reply has wrong size : ", res.len
          quit QuitFailure
        let reply = res[0].int
        pkt_idx = res[1].int + res[2].int*256
        if reply == RFB_SEND_PKT:
          stderr.writeLine "We resend the last packet"
        elif reply == RFB_WRONG_CRC:
          stderr.writeLine "CRC check failed"
          quit QuitFailure
        elif reply == RFB_SUCCESS:
          stderr.writeLine "Success !"
          stderr.writeLine "Upload time = ", (epochTime()-startUploadTime).formatFloat(precision=3)
          break;
        else:
          stderr.writeLine "Unexpected reply code at the end of the upload process :", pkt_idx
          quit QuitFailure
        #
      #
      else:
        res = port.getPacket(200000,3)
        if res == nil:
          stderr.writeLine "Got no reply at pkt_idx : ", pkt_idx
          quit QuitFailure
        if res.len != 3:
          stderr.writeLine "Wrong message length at pkt_idx : ", pkt_idx, "msglen = ", res.len, " ", res
          quit QuitFailure
        if res[0].int != RFB_SEND_PKT:
          stderr.writeLine "Expected RFB_SEND_PKT command : pkt_idx=", pkt_idx , " reply=", res[0].int , " ", res[1].int, " ", res[2].int ##NEW EDIT
          quit QuitFailure
        # auto parakamptei to 5088 bug
        #if res[2].int>=128:
        #  pkt_idx = res[1].int + (res[2].int-128)*256
        #else:
        pkt_idx = res[1].int + res[2].int*256
        #stderr.writeLine pkt_idx
      if pkt_idx == pkt_idx_prev:
        stderr.writeLine "Resend"
      #elif pkt_idx == 30688:
      #  stderr.writeLine "Fix the 119 to 19"
      #  pkt_idx = 5088
      elif pkt_idx  !=  (pkt_idx_prev - 32) :
        stderr.writeLine "Protocol error: expected pkt_idx==", pkt_idx_prev - 32, ". Got ", pkt_idx
        # To fovero 5088 bug !
        # Protocol error: expected pkt_idx==5088. Got 1248
        # pairnoume "4 224 4 224 4 224 4 224 4 224 4 224 4 224 4 224 4 224 4 224"
        # pou vasika einai 10 fores to "4 224"
        # enw tha prepe na einai "4 224 19"  opou 4 == RFB_SEND_PKT kai "224 19" == 5088
        # O usb2rf to pairnei !!!
        # O usb2rf  den to stelnei i to ftdi den to stelnei i to serial sto PC !!
        # molis emfanistei to bug prepei na exw debug to usb2rf
        # isws na exei sxesi me ta timings giati meta apo kapoio diastima douleuei xwris kapoia allagi
        # alla kai pali giati emfanizetai sto idx = 5088 ?
        #if pkt_idx_prev - 32 == 5088 and pkt_idx == 1248 :
        #  stderr.writeLine "This is the fovero 5088 bug"
          #pkt_idx = 5088
        #else:
        res = res & port.getPacket(1000000,100)
        stderr.writeLine res.len
        for c in res:
          stderr.write c.int," "
        quit QuitFailure
      pkt_idx_prev=pkt_idx
      ################################# END upload method 0 ##################################
  elif upload_method == 1:
    # The method:1 offloads the job to usb2rf module
    ###### The new method offload the send/receive functions to usb2rf module
    stderr.writeLine "Using the new method 1"
    var pkt_idx = app.len
    let applen = app.len.uint16.toString

    port.write CommdModeStr & "U" & applen
    #port.drain(5000) # TODO .. better just a delay
    #port.write header # We send the header
    #port.write app[pkt_idx-PAYLOAD..pkt_idx-1] # and 1 more packet in advance
    #pkt_idx-=PAYLOAD
    #port.write app[pkt_idx-PAYLOAD..pkt_idx-1] # and 1 more packet in advance
    #pkt_idx-=PAYLOAD
    while pkt_idx>0:
      let resp=port.getChar()
      if resp == -1:
        continue
      elif resp=='P'.int:
        #stderr.writeLine pkt_idx
        port.write app[pkt_idx-PAYLOAD..pkt_idx-1]
        pkt_idx -= PAYLOAD
      #elif resp==RFB_NO_SIGNATURE:
      #  stderr.writeLine "rfboot reports the signature is wrong" # TODO
      #  quit QuitFailure
      #elif resp==RFB_INVALID_CODE_SIZE:
      #  stderr.writeLine "rfboot reports the code size is invalid" # TODO
      #  quit QuitFailure
      elif resp=='A'.int:
        discard
        # TODO
      elif resp=='R'.int:
        stderr.writeLine "Resend"
      else:
        stderr.writeLine "Got unknown response", resp
        quit QuitFailure
    #port.drain(3000)
    # TODO timeout
    var resp:int
    while (resp!='E'.int):
      resp=port.getChar(250000)

    stderr.writeLine "All packets sent"
    ############# end method 1 #################
  #
  # We got success reply
  #
  let f = open(".lastupload", fmWrite)
  f.writeLine newAppChannel
  f.writeLine newAppAddress[0].int
  f.writeLine newAppAddress[1].int
  f.writeLine newResetString
  f.close()
  port.setChannel newAppChannel
  port.setAddress newAppAddress
  copyFile(binaryFileName, ".lastbinary")


proc actionMonitor() =
  let (appChannel, appAddress, resetString) = getAppParams()
  discard resetString
  let p = commandLineParams()
  let portName = getPortName()
  stderr.writeLine "portname=", portName
  let fd = portName.openPort()
  stderr.writeLine "Application SyncWord = ", appAddress.toArray
  stderr.writeLine "Channel = ", appChannel
  fd.setChannel appChannel
  sleep 20
  fd.setAddress appAddress
  sleep 20
  discard fd.close()
  if p.len >= 2:
    let pid = checkLockFile(portName)
    if (pid>0):
      stderr.writeLine "Serial port \"", portName, "\" is in use, not executing command"
    else:
      #echo "TODO"
      #stderr.writeLine "/bin/fuser -s ", portName
      #let pr = startProcess( command="/bin/fuser", args=["-s", portName], options={poStdErrToStdOut} )
      #let e = waitForExit(pr)
      #if e == 0:
      #  stderr.writeLine "Serial port ", portName, " is in use, not executing command"
      #else:
      #block:
      stderr.write "Executing : \"" #, p[1..p.len-1]
      for i in p:
        stderr.write i, " "
      stderr.writeLine("\"")
      discard startProcess( command=p[1], args=p[2..p.len-1] & portName, options={poStdErrToStdOut,poUsePath} )


proc actionResetLocal() =
  let portname = getPortName()
  let fd = portname.openPort()
  # This command resets the usb2rf module
  stderr.writeLine "reseting the usb2rf module"
  # string=" & CommdModeStr & "R"
  fd.write CommdModeStr & "R"

proc actionGetPort() =
  echo getPortName()

proc actionAddPort() =
  discard
  stderr.writeLine "Waiting for a new module to be inserted to a USB port"
  #let knownPorts = getKnownPorts()
  var port:string

  block GetNewPort:
    var connectedPorts = getConnectedPorts()
    for t in 1..60: # 60 sec
      var oldConnectedPorts = connectedPorts
      connectedPorts=getConnectedPorts()
      if connectedPorts.len>oldConnectedPorts.len:
        for p in connectedPorts:
          if not (port in oldConnectedPorts):
            
            port = p
            break GetNewPort
      sleep(1000)
    stderr.writeLine "Timeour"
    quit QuitFailure

  if port in getKnownPorts():
    stderr.writeLine "The port is already in ", homeconfig
  else:
    stderr.writeLine "Adding port : ", port
    let f=homeconfig.expandtilde.open(mode=fmAppend)
    f.writeLine ""
    f.writeLine "# port added with \"rftool addport\""
    f.writeLine port
    f.close


  
      

# implements command line parsing and returns all the parameters in a tuple
proc main() =
  let p = commandLineParams() # nim's standard library function
  if p.len == 0:
    stderr.writeLine ""
    stderr.writeLine "rftool: rfboot utility"
    stderr.writeLine ""
    stderr.writeLine "Usage : rftool create ProjectName # Creates a new Arduino based project"
    stderr.writeLine "        rftool upload|send SomeFirmware.bin"
    stderr.writeLine "        rftool monitor term_emulator_cmd arg arg -p #opens a serial terminal with the correct parameters"
    stderr.writeLine "        rftool resetlocal"
    stderr.writeLine "        rftool getport"
    stderr.writeLine "        rftool addport # Adds usb2rf module to ~/.usb2rf file"
    quit QuitFailure
  let action = p[0].strip.normalize # mikra xoris _
  case action
  of "create":
    actionCreate()
  of "upload","send":
    if p.len == 1:
      stderr.writeLine "No firmware file given"
      quit QuitFailure
    elif p.len>=3:
      stderr.writeLine "Too many arguments"
      quit QuitFailure
    let binary = p[1].strip
    actionUpload(binary)
  of "monitor":
    actionMonitor()
  of "resetlocal":
    actionResetLocal()
  of "getport":
    actionGetPort()
  of "addport":
    actionAddPort()
  else:
    stderr.writeLine "Unknown command \"", action,"\""
    quit QuitFailure


when isMainModule:
  main()
