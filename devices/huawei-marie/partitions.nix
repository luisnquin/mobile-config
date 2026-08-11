# Generated from the `.563` base package's HISIUFS_GPT packet by
# tools/extract-ota-packet.py. See firmware.nix `partitionTable` for how this
# was validated. Do not hand-edit; regenerate instead.
{
  logicalBlockBytes = 4096;
  entryCount = 67;
  partitions = {
    vrl = {
      slot = 1;
      firstBlock = 128;
      lastBlock = 255;
      sizeKiB = 512;
    };
    vrl_backup = {
      slot = 2;
      firstBlock = 256;
      lastBlock = 383;
      sizeKiB = 512;
    };
    modem_secure = {
      slot = 3;
      firstBlock = 384;
      lastBlock = 2559;
      sizeKiB = 8704;
    };
    nvme = {
      slot = 4;
      firstBlock = 2560;
      lastBlock = 3839;
      sizeKiB = 5120;
    };
    certification = {
      slot = 5;
      firstBlock = 3840;
      lastBlock = 4095;
      sizeKiB = 1024;
    };
    oeminfo = {
      slot = 6;
      firstBlock = 4096;
      lastBlock = 20479;
      sizeKiB = 65536;
    };
    secure_storage = {
      slot = 7;
      firstBlock = 20480;
      lastBlock = 28671;
      sizeKiB = 32768;
    };
    modem_om = {
      slot = 8;
      firstBlock = 28672;
      lastBlock = 36863;
      sizeKiB = 32768;
    };
    modemnvm_factory = {
      slot = 9;
      firstBlock = 36864;
      lastBlock = 40959;
      sizeKiB = 16384;
    };
    modemnvm_backup = {
      slot = 10;
      firstBlock = 40960;
      lastBlock = 45055;
      sizeKiB = 16384;
    };
    modemnvm_img = {
      slot = 11;
      firstBlock = 45056;
      lastBlock = 53759;
      sizeKiB = 34816;
    };
    reserved7 = {
      slot = 12;
      firstBlock = 53760;
      lastBlock = 54271;
      sizeKiB = 2048;
    };
    hisee_encos = {
      slot = 13;
      firstBlock = 54272;
      lastBlock = 55295;
      sizeKiB = 4096;
    };
    veritykey = {
      slot = 14;
      firstBlock = 55296;
      lastBlock = 55551;
      sizeKiB = 1024;
    };
    ddr_para = {
      slot = 15;
      firstBlock = 55552;
      lastBlock = 55807;
      sizeKiB = 1024;
    };
    modem_driver = {
      slot = 16;
      firstBlock = 55808;
      lastBlock = 60927;
      sizeKiB = 20480;
    };
    ramdisk = {
      slot = 17;
      firstBlock = 60928;
      lastBlock = 61439;
      sizeKiB = 2048;
    };
    vbmeta_system = {
      slot = 18;
      firstBlock = 61440;
      lastBlock = 61695;
      sizeKiB = 1024;
    };
    vbmeta_vendor = {
      slot = 19;
      firstBlock = 61696;
      lastBlock = 61951;
      sizeKiB = 1024;
    };
    vbmeta_odm = {
      slot = 20;
      firstBlock = 61952;
      lastBlock = 62207;
      sizeKiB = 1024;
    };
    vbmeta_cust = {
      slot = 21;
      firstBlock = 62208;
      lastBlock = 62463;
      sizeKiB = 1024;
    };
    vbmeta_hw_product = {
      slot = 22;
      firstBlock = 62464;
      lastBlock = 62719;
      sizeKiB = 1024;
    };
    splash2 = {
      slot = 23;
      firstBlock = 62720;
      lastBlock = 83199;
      sizeKiB = 81920;
    };
    bootfail_info = {
      slot = 24;
      firstBlock = 83200;
      lastBlock = 83711;
      sizeKiB = 2048;
    };
    misc = {
      slot = 25;
      firstBlock = 83712;
      lastBlock = 84223;
      sizeKiB = 2048;
    };
    dfx = {
      slot = 26;
      firstBlock = 84224;
      lastBlock = 88319;
      sizeKiB = 16384;
    };
    rrecord = {
      slot = 27;
      firstBlock = 88320;
      lastBlock = 92415;
      sizeKiB = 16384;
    };
    fw_lpm3 = {
      slot = 28;
      firstBlock = 92416;
      lastBlock = 92479;
      sizeKiB = 256;
    };
    kpatch = {
      slot = 29;
      firstBlock = 92480;
      lastBlock = 93439;
      sizeKiB = 3840;
    };
    hdcp = {
      slot = 30;
      firstBlock = 93440;
      lastBlock = 93695;
      sizeKiB = 1024;
    };
    hisee_img = {
      slot = 31;
      firstBlock = 93696;
      lastBlock = 94719;
      sizeKiB = 4096;
    };
    hhee = {
      slot = 32;
      firstBlock = 94720;
      lastBlock = 95743;
      sizeKiB = 4096;
    };
    hisee_fs = {
      slot = 33;
      firstBlock = 95744;
      lastBlock = 97791;
      sizeKiB = 8192;
    };
    fastboot = {
      slot = 34;
      firstBlock = 97792;
      lastBlock = 100863;
      sizeKiB = 12288;
    };
    vector = {
      slot = 35;
      firstBlock = 100864;
      lastBlock = 101887;
      sizeKiB = 4096;
    };
    isp_boot = {
      slot = 36;
      firstBlock = 101888;
      lastBlock = 102399;
      sizeKiB = 2048;
    };
    isp_firmware = {
      slot = 37;
      firstBlock = 102400;
      lastBlock = 105983;
      sizeKiB = 14336;
    };
    fw_hifi = {
      slot = 38;
      firstBlock = 105984;
      lastBlock = 109055;
      sizeKiB = 12288;
    };
    teeos = {
      slot = 39;
      firstBlock = 109056;
      lastBlock = 111103;
      sizeKiB = 8192;
    };
    sensorhub = {
      slot = 40;
      firstBlock = 111104;
      lastBlock = 115199;
      sizeKiB = 16384;
    };
    erecovery_kernel = {
      slot = 41;
      firstBlock = 115200;
      lastBlock = 121343;
      sizeKiB = 24576;
    };
    erecovery_ramdisk = {
      slot = 42;
      firstBlock = 121344;
      lastBlock = 129535;
      sizeKiB = 32768;
    };
    erecovery_vendor = {
      slot = 43;
      firstBlock = 129536;
      lastBlock = 133631;
      sizeKiB = 16384;
    };
    kernel = {
      slot = 44;
      firstBlock = 133632;
      lastBlock = 139775;
      sizeKiB = 24576;
    };
    eng_system = {
      slot = 45;
      firstBlock = 139776;
      lastBlock = 142847;
      sizeKiB = 12288;
    };
    recovery_ramdisk = {
      slot = 46;
      firstBlock = 142848;
      lastBlock = 151039;
      sizeKiB = 32768;
    };
    recovery_vendor = {
      slot = 47;
      firstBlock = 151040;
      lastBlock = 155135;
      sizeKiB = 16384;
    };
    dts = {
      slot = 48;
      firstBlock = 155136;
      lastBlock = 157183;
      sizeKiB = 8192;
    };
    dto = {
      slot = 49;
      firstBlock = 157184;
      lastBlock = 163327;
      sizeKiB = 24576;
    };
    trustfirmware = {
      slot = 50;
      firstBlock = 163328;
      lastBlock = 163839;
      sizeKiB = 2048;
    };
    modem_fw = {
      slot = 51;
      firstBlock = 163840;
      lastBlock = 178175;
      sizeKiB = 57344;
    };
    eng_vendor = {
      slot = 52;
      firstBlock = 178176;
      lastBlock = 181247;
      sizeKiB = 12288;
    };
    modem_patch_nv = {
      slot = 53;
      firstBlock = 181248;
      lastBlock = 182271;
      sizeKiB = 4096;
    };
    reserved4 = {
      slot = 54;
      firstBlock = 182272;
      lastBlock = 184319;
      sizeKiB = 8192;
    };
    recovery_vbmeta = {
      slot = 55;
      firstBlock = 184320;
      lastBlock = 184831;
      sizeKiB = 2048;
    };
    erecovery_vbmeta = {
      slot = 56;
      firstBlock = 184832;
      lastBlock = 185343;
      sizeKiB = 2048;
    };
    vbmeta = {
      slot = 57;
      firstBlock = 185344;
      lastBlock = 186367;
      sizeKiB = 4096;
    };
    modemnvm_update = {
      slot = 58;
      firstBlock = 186368;
      lastBlock = 190463;
      sizeKiB = 16384;
    };
    modemnvm_cust = {
      slot = 59;
      firstBlock = 190464;
      lastBlock = 194559;
      sizeKiB = 16384;
    };
    patch = {
      slot = 60;
      firstBlock = 194560;
      lastBlock = 202751;
      sizeKiB = 32768;
    };
    cache = {
      slot = 61;
      firstBlock = 202752;
      lastBlock = 229375;
      sizeKiB = 106496;
    };
    preas = {
      slot = 62;
      firstBlock = 229376;
      lastBlock = 487423;
      sizeKiB = 1032192;
    };
    preavs = {
      slot = 63;
      firstBlock = 487424;
      lastBlock = 495615;
      sizeKiB = 32768;
    };
    super = {
      slot = 64;
      firstBlock = 495616;
      lastBlock = 1800191;
      sizeKiB = 5218304;
    };
    version = {
      slot = 65;
      firstBlock = 1800192;
      lastBlock = 1947647;
      sizeKiB = 589824;
    };
    preload = {
      slot = 66;
      firstBlock = 1947648;
      lastBlock = 2240511;
      sizeKiB = 1171456;
    };
    userdata = {
      slot = 67;
      firstBlock = 2240512;
      lastBlock = 3289087;
      sizeKiB = 4194304;
    };
  };
}
