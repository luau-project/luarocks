-- Detect the operating system and architecture without forking a subprocess.
--
-- We are not going for exhaustive list of every historical system here,
-- but aiming to cover every platform where LuaRocks is known to run.
-- If your system is not detected, patches are welcome!

local record sysdetect
   enum Processor
      "unknown"
      "sparc"
      "x86"
      "mips"
      "hppa"
      "sparcv8"
      "ppc"
      "ppc64"
      "ppc64le"
      "s390"
      "arm"
      "armv7l"
      "arm64"
      "superh"
      "sparcv9"
      "ia_64"
      "x86_64"
      "alpha"
      "aarch64"
      "riscv64"
      "alpha"
   end
   
   enum System
      "sysv"
      "hpux"
      "netbsd"
      "linux"
      "hurd"
      "solaris"
      "aix"
      "irix"
      "freebsd"
      "openbsd"
      "dragonfly"
      "haiku"
      "windows"
      "cygwin"
      "macosx"
   end
end

local type System = sysdetect.System
local type Processor = sysdetect.Processor

local enum Endian
   "little"
   "big"
end

local function hex(s: string): string
   return (s:gsub("$(..)", function(x: string): string
      return string.char(tonumber(x, 16))
   end))
end

local function read_int8(fd: FILE): integer
   if io.type(fd) == "closed file" then
      return nil
   end
   local s = fd:read(1)
   if not s then
      fd:close()
      return nil
   end
   return s:byte()
end

local function bytes2number(s: string, endian: Endian): integer
   local r: integer = 0
   if endian == "little" then
      for i = #s, 1, -1 do
         r = r*256 + s:byte(i,i)
      end
   else
      for i = 1, #s do
         r = r*256 + s:byte(i,i)
      end
   end
   return r
end

local function read(fd: FILE, bytes: integer, endian: Endian): integer
   if io.type(fd) == "closed file" then
      return nil
   end
   local s: string = fd:read(bytes)
   if not s
      then fd:close()
      return nil
   end
   return bytes2number(s, endian)
end

local function read_int32le(fd: FILE): integer
   return read(fd, 4, "little")
end

--------------------------------------------------------------------------------
-- @section ELF
--------------------------------------------------------------------------------

local record ElfHeader
   osabi: integer
   bits: integer
   endian: integer
   elf_version: integer
   word: integer
   e_type: integer
   e_entry: integer
   e_phoff: integer
   e_shoff: integer
   e_flags: integer
   e_ehsize: integer
   e_phentsize: integer
   e_phnum: integer
   e_shentsize: integer
   e_shnum: integer
   e_shstrndx: integer
end

local record ElfSection
   sh_name_off: integer
   sh_type: integer
   sh_flags: integer
   sh_addr: integer
   sh_offset: integer
   sh_size: integer
   sh_link: integer
   sh_info: integer

   name: string
   namesz: integer
   namedata: string
   descsz: integer
   descdata: string
   type: integer
end

local endians: {integer:Endian} = {
   [0x01] = "little",
   [0x02] = "big",
}

local e_osabi: {integer:System} = {
   [0x00] = "sysv",
   [0x01] = "hpux",
   [0x02] = "netbsd",
   [0x03] = "linux",
   [0x04] = "hurd",
   [0x06] = "solaris",
   [0x07] = "aix",
   [0x08] = "irix",
   [0x09] = "freebsd",
   [0x0c] = "openbsd",
}

local e_machines: {integer:Processor} = {
   [0x02] = "sparc",
   [0x03] = "x86",
   [0x08] = "mips",
   [0x0f] = "hppa",
   [0x12] = "sparcv8",
   [0x14] = "ppc",
   [0x15] = "ppc64",
   [0x16] = "s390",
   [0x28] = "arm",
   [0x2a] = "superh",
   [0x2b] = "sparcv9",
   [0x32] = "ia_64",
   [0x3E] = "x86_64",
   [0xB6] = "alpha",
   [0xB7] = "aarch64",
   [0xF3] = "riscv64",
   [0x9026] = "alpha",
}

local SHT_NOTE <const> = 7

local function read_elf_section_headers(fd: FILE, hdr: ElfHeader): {string: ElfSection}
   local endian = endians[hdr.endian]
   local word: integer = hdr.word

   local strtab_offset: integer
   local sections: {string:ElfSection} = {}
   local secarray: {ElfSection} = {}
   for i = 0, hdr.e_shnum - 1 do
      fd:seek("set", hdr.e_shoff + (i * hdr.e_shentsize))
      local section: ElfSection = {}
      section.sh_name_off = read(fd, 4, endian)
      section.sh_type = read(fd, 4, endian)
      section.sh_flags = read(fd, word, endian)
      section.sh_addr = read(fd, word, endian)
      section.sh_offset = read(fd, word, endian)
      section.sh_size = read(fd, word, endian)
      section.sh_link = read(fd, 4, endian)
      section.sh_info = read(fd, 4, endian)
      if section.sh_type == SHT_NOTE then
         fd:seek("set", section.sh_offset)
         section.namesz = read(fd, 4, endian)
         section.descsz = read(fd, 4, endian)
         section.type = read(fd, 4, endian)
         section.namedata = fd:read(section.namesz):gsub("%z.*", "")
         section.descdata = fd:read(section.descsz)
      elseif i == hdr.e_shstrndx then
         strtab_offset = section.sh_offset
      end
      table.insert(secarray, section)
   end
   if strtab_offset then
      for _, section in ipairs(secarray) do
         fd:seek("set", strtab_offset + section.sh_name_off)
         section.name = fd:read(32):gsub("%z.*", "")
         sections[section.name] = section
      end
   end
   return sections
end

local function detect_elf_system(fd: FILE, hdr: ElfHeader, sections: {string:ElfSection}): System
   local system = e_osabi[hdr.osabi]
   local endian = endians[hdr.endian]

   if system == "sysv" then
      local abitag = sections[".note.ABI-tag"]
      if abitag then
         if abitag.namedata == "GNU" and abitag.type == 1
           and abitag.descdata:sub(0, 4) == "\0\0\0\0" then
            return "linux"
         end
      elseif sections[".SUNW_version"]
        or sections[".SUNW_signature"] then
         return "solaris"
      elseif sections[".note.netbsd.ident"] then
         return "netbsd"
      elseif sections[".note.openbsd.ident"] then
         return "openbsd"
      elseif sections[".note.tag"] and
             sections[".note.tag"].namedata == "DragonFly" then
         return "dragonfly"
      end

      local gnu_version_r = sections[".gnu.version_r"]
      if gnu_version_r then

         local dynstr = sections[".dynstr"].sh_offset

         local idx = 0
         for _ = 0, gnu_version_r.sh_info - 1 do
            fd:seek("set", gnu_version_r.sh_offset + idx)
            assert(read(fd, 2, endian)) -- vn_version
            local vn_cnt = read(fd, 2, endian)
            local vn_file = read(fd, 4, endian)
            local vn_next = read(fd, 2, endian)

            fd:seek("set", dynstr + vn_file)
            local libname = fd:read(64):gsub("%z.*", "")

            if hdr.e_type == 0x03 and libname == "libroot.so" then
               return "haiku"
            elseif libname:match("linux") then
               return "linux"
            end

            idx = idx + (vn_next * (vn_cnt + 1))
         end
      end

      local procfile = io.open("/proc/sys/kernel/ostype")
      if procfile then
         local version = procfile:read(6)
         procfile:close()
         if version == "Linux\n" then
            return "linux"
         end
      end
   end

   return system
end

local function read_elf_header(fd: FILE): ElfHeader, Processor
   local hdr: ElfHeader = {}

   hdr.bits = read_int8(fd)
   hdr.endian = read_int8(fd)
   hdr.elf_version = read_int8(fd)
   if hdr.elf_version ~= 1 then
      return nil
   end
   hdr.osabi = read_int8(fd)
   if not hdr.osabi then
      return nil
   end

   local endian = endians[hdr.endian]
   fd:seek("set", 0x10)
   hdr.e_type = read(fd, 2, endian)
   local machine = read(fd, 2, endian)
   local processor = e_machines[machine] or "unknown"
   if endian == "little" and processor == "ppc64" then
      processor = "ppc64le"
   end

   local elfversion = read(fd, 4, endian)
   if elfversion ~= 1 then
      return nil
   end

   local word = (hdr.bits == 1) and 4 or 8
   hdr.word = word

   hdr.e_entry = read(fd, word, endian)
   hdr.e_phoff = read(fd, word, endian)
   hdr.e_shoff = read(fd, word, endian)
   hdr.e_flags = read(fd, 4, endian)
   hdr.e_ehsize = read(fd, 2, endian)
   hdr.e_phentsize = read(fd, 2, endian)
   hdr.e_phnum = read(fd, 2, endian)
   hdr.e_shentsize = read(fd, 2, endian)
   hdr.e_shnum = read(fd, 2, endian)
   hdr.e_shstrndx = read(fd, 2, endian)

   return hdr, processor
end

local function detect_elf(fd: FILE): System, Processor
   local hdr, processor = read_elf_header(fd)
   if not hdr then
      return nil
   end
   local sections = read_elf_section_headers(fd, hdr)
   local system = detect_elf_system(fd, hdr, sections)
   return system, processor
end

--------------------------------------------------------------------------------
-- @section Mach Objects (Apple)
--------------------------------------------------------------------------------

local mach_l64: {integer:Processor} = {
   [7] = "x86_64",
   [12] = "aarch64",
}

local mach_b64: {integer:Processor} = {
   [0] = "ppc64",
}

local mach_l32: {integer:Processor} = {
   [7] = "x86",
   [12] = "arm",
}

local mach_b32: {integer:Processor} = {
   [0] = "ppc",
}

local function detect_mach(magic: string, fd: FILE): System, Processor
   if not magic then
      return nil
   end

   if magic == hex("$CA$FE$BA$BE") then
      -- fat binary, go for the first one
      fd:seek("set", 0x12)
      local offs = read_int8(fd)
      if not offs then
         return nil
      end
      fd:seek("set", offs * 256)
      magic = fd:read(4)
      return detect_mach(magic, fd)
   end

   local cputype = read_int8(fd)

   if magic == hex("$CF$FA$ED$FE") then
      return "macosx", mach_l64[cputype] or "unknown"
   elseif magic == hex("$FE$ED$CF$FA") then
      return "macosx", mach_b64[cputype] or "unknown"
   elseif magic == hex("$CE$FA$ED$FE") then
      return "macosx", mach_l32[cputype] or "unknown"
   elseif magic == hex("$FE$ED$FA$CE") then
      return "macosx", mach_b32[cputype] or "unknown"
   end
end

--------------------------------------------------------------------------------
-- @section PE (Windows)
--------------------------------------------------------------------------------

local pe_machine = {
    [0x8664] = "x86_64",
    [0x01c0] = "arm",
    [0x01c4] = "armv7l",
    [0xaa64] = "arm64",
    [0x014c] = "x86",
}

local function detect_pe(fd: FILE): System, Processor
   fd:seek("set", 60)                 -- position of PE header position
   local peoffset = read_int32le(fd)  -- read position of PE header
   if not peoffset then
      return nil
   end
   local system: System = "windows"
   fd:seek("set", peoffset + 4)       -- move to position of Machine section
   local machine = read(fd, 2, "little")
   local processor: Processor = pe_machine[machine]

   local rdata_pos_s = fd:read(736):match(".rdata%z%z............(....)")
   if rdata_pos_s then
      local rdata_pos = bytes2number(rdata_pos_s, "little")
      fd:seek("set", rdata_pos)
      local data = fd:read(512)
      if data:match("cygwin") or data:match("cyggcc") then
         system = "cygwin"
      end
   end

   return system, processor or "unknown"
end

--------------------------------------------------------------------------------
-- @section API
--------------------------------------------------------------------------------

function sysdetect.detect_file(file: string): System, Processor
   local fd = io.open(file, "rb")
   if not fd then
      return nil
   end
   local magic = fd:read(4)
   if magic == hex("$7FELF") then
      return detect_elf(fd)
   end
   if magic == hex("MZ$90$00") then
      return detect_pe(fd)
   end
   return detect_mach(magic, fd)
end

local cache_system: System
local cache_processor: Processor

function sysdetect.detect(input_file: string): System, Processor
   local dirsep = package.config:sub(1,1)
   local files: {string}

   if input_file then
      files = { input_file }
   else
      if cache_system then
         return cache_system, cache_processor
      end

      local PATHsep: string
      local interp = arg and arg[-1]
      if dirsep == "/" then
         -- Unix
         files = {
            "/bin/sh", -- Unix: well-known POSIX path
            "/proc/self/exe", -- Linux: this should always have a working binary
         }
         PATHsep = ":"
      else
         -- Windows
         local systemroot = os.getenv("SystemRoot")
         files = {
            systemroot .. "\\system32\\notepad.exe", -- well-known Windows path
            systemroot .. "\\explorer.exe", -- well-known Windows path
         }
         if interp and not interp:lower():match("exe$") then
            interp = interp .. ".exe"
         end
         PATHsep = ";"
      end
      if interp then
         if interp:match(dirsep) then
            -- interpreter path is absolute
            table.insert(files, 1, interp)
         else
            for d in (os.getenv("PATH") or ""):gmatch("[^"..PATHsep.."]+") do
               table.insert(files, d .. dirsep .. interp)
            end
         end
      end
   end
   for _, f in ipairs(files) do
      local system, processor = sysdetect.detect_file(f)
      if system then
         cache_system = system
         cache_processor = processor
         return system, processor
      end
   end
end

return sysdetect
