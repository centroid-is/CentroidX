import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'industrial_icons.dart';

export 'industrial_icons.dart'
    show industrialIcons, industrialIconGroups, industrialIconNames;

const IconData baadericon =
    IconData(0xe800, fontFamily: "TfcIcons", fontPackage: "tfc");
const IconData warehouse_open =
    IconData(0xe801, fontFamily: "TfcIcons", fontPackage: "tfc");
const IconData warehouse_open1 =
    IconData(0xe803, fontFamily: "TfcIcons", fontPackage: "tfc");
const IconData warehouse_open2 =
    IconData(0xe804, fontFamily: "TfcIcons", fontPackage: "tfc");
const IconData warehouse_closed =
    IconData(0xe805, fontFamily: "TfcIcons", fontPackage: "tfc");
const IconData pallet_top =
    IconData(0xe806, fontFamily: "TfcIcons", fontPackage: "tfc");
const IconData pallet_stack =
    IconData(0xe807, fontFamily: "TfcIcons", fontPackage: "tfc");
const IconData ethercaticon =
    IconData(0xe808, fontFamily: "TfcIcons", fontPackage: "tfc");

class IconDataConverter implements JsonConverter<IconData, String> {
  const IconDataConverter();

  @override
  IconData fromJson(String json) {
    // Use a predefined map of constant icons instead of creating new instances
    return _getIconByName(json);
  }

  @override
  String toJson(IconData iconData) {
    // Store icon name instead of full IconData properties
    return _getIconName(iconData);
  }

  // Predefined map of constant icons
  static IconData _getIconByName(String name) {
    // The industrial glyphs are generated, so they are looked up in their map
    // rather than restated as another few dozen cases here.
    final industrial = industrialIcons[name];
    if (industrial != null) return industrial;
    switch (name) {
      // Navigation & Basic UI
      case 'home':
        return Icons.home;
      case 'settings':
        return Icons.settings;
      case 'dashboard':
        return Icons.dashboard;
      case 'menu':
        return Icons.menu;
      case 'close':
        return Icons.close;
      case 'arrow_back':
        return Icons.arrow_back;
      case 'arrow_forward':
        return Icons.arrow_forward;
      case 'expand_more':
        return Icons.expand_more;
      case 'expand_less':
        return Icons.expand_less;
      case 'keyboard_arrow_up':
        return Icons.keyboard_arrow_up;
      case 'keyboard_arrow_down':
        return Icons.keyboard_arrow_down;
      case 'keyboard_arrow_left':
        return Icons.keyboard_arrow_left;
      case 'keyboard_arrow_right':
        return Icons.keyboard_arrow_right;

      // Analytics & Data
      case 'analytics':
        return Icons.analytics;
      case 'assessment':
        return Icons.assessment;
      case 'trending_up':
        return Icons.trending_up;
      case 'trending_down':
        return Icons.trending_down;
      case 'show_chart':
        return Icons.show_chart;
      case 'bar_chart':
        return Icons.bar_chart;
      case 'pie_chart':
        return Icons.pie_chart;
      case 'table_chart':
        return Icons.table_chart;
      case 'insert_chart':
        return Icons.insert_chart;
      case 'query_stats':
        return Icons.query_stats;
      case 'insights':
        return Icons.insights;
      case 'data_usage':
        return Icons.data_usage;
      case 'dataset':
        return Icons.dataset;
      case 'storage':
        return Icons.storage;
      case 'cloud':
        return Icons.cloud;
      case 'cloud_download':
        return Icons.cloud_download;
      case 'cloud_upload':
        return Icons.cloud_upload;
      case 'cloud_sync':
        return Icons.cloud_sync;

      // Monitoring & Control
      case 'monitor':
        return Icons.monitor;
      case 'monitor_heart':
        return Icons.monitor_heart;
      case 'speed':
        return Icons.speed;
      case 'timer':
        return Icons.timer;
      case 'schedule':
        return Icons.schedule;
      case 'alarm':
        return Icons.alarm;
      case 'notifications':
        return Icons.notifications;
      case 'notifications_active':
        return Icons.notifications_active;
      case 'notifications_off':
        return Icons.notifications_off;
      case 'warning':
        return Icons.warning;
      case 'error':
        return Icons.error;
      case 'info':
        return Icons.info;
      case 'check_circle':
        return Icons.check_circle;
      case 'cancel':
        return Icons.cancel;
      case 'help':
        return Icons.help;
      case 'help_outline':
        return Icons.help_outline;

      // Engineering & Manufacturing
      case 'tune':
        return Icons.tune;
      case 'build':
        return Icons.build;
      case 'engineering':
        return Icons.engineering;
      case 'precision_manufacturing':
        return Icons.precision_manufacturing;
      case 'factory':
        return Icons.factory;
      case 'warehouse':
        return Icons.warehouse;
      case 'inventory':
        return Icons.inventory;
      case 'inventory_2':
        return Icons.inventory_2;
      case 'local_shipping':
        return Icons.local_shipping;
      case 'local_shipping_outlined':
        return Icons.local_shipping_outlined;
      case 'construction':
        return Icons.construction;
      case 'handyman':
        return Icons.handyman;
      case 'plumbing':
        return Icons.plumbing;
      case 'electrical_services':
        return Icons.electrical_services;
      case 'architecture':
        return Icons.architecture;
      case 'agriculture':
        return Icons.agriculture;
      case 'forest':
        return Icons.forest;
      case 'park':
        return Icons.park;

      // Tools & Equipment
      case 'build_circle':
        return Icons.build_circle;
      case 'hardware':
        return Icons.hardware;
      case 'memory':
        return Icons.memory;
      case 'dns':
        return Icons.dns;
      case 'router':
        return Icons.router;
      case 'wifi':
        return Icons.wifi;
      case 'bluetooth':
        return Icons.bluetooth;
      case 'usb':
        return Icons.usb;
      case 'cable':
        return Icons.cable;
      case 'power':
        return Icons.power;
      case 'power_off':
        return Icons.power_off;
      case 'battery_full':
        return Icons.battery_full;
      case 'battery_charging_full':
        return Icons.battery_charging_full;
      case 'battery_alert':
        return Icons.battery_alert;
      case 'bolt':
        return Icons.bolt;
      case 'flash_on':
        return Icons.flash_on;
      case 'electric_bolt':
        return Icons.electric_bolt;

      // View & Display
      case 'view_list':
        return Icons.view_list;
      case 'view_module':
        return Icons.view_module;
      case 'view_quilt':
        return Icons.view_quilt;
      case 'view_agenda':
        return Icons.view_agenda;
      case 'view_column':
        return Icons.view_column;
      case 'view_headline':
        return Icons.view_headline;
      case 'view_stream':
        return Icons.view_stream;
      case 'view_week':
        return Icons.view_week;
      case 'view_day':
        return Icons.view_day;
      case 'view_carousel':
        return Icons.view_carousel;
      case 'view_comfy':
        return Icons.view_comfy;
      case 'view_compact':
        return Icons.view_compact;
      case 'view_compact_alt':
        return Icons.view_compact_alt;
      case 'view_cozy':
        return Icons.view_cozy;
      case 'view_in_ar':
        return Icons.view_in_ar;
      case 'view_kanban':
        return Icons.view_kanban;
      case 'view_sidebar':
        return Icons.view_sidebar;
      case 'view_timeline':
        return Icons.view_timeline;
      case 'view_array':
        return Icons.view_array;
      case 'view_comfortable':
        return Icons.view_comfortable;
      case 'view_day_outlined':
        return Icons.view_day_outlined;
      case 'view_week_outlined':
        return Icons.view_week_outlined;
      case 'view_headline_outlined':
        return Icons.view_headline_outlined;
      case 'view_carousel_outlined':
        return Icons.view_carousel_outlined;
      case 'view_column_outlined':
        return Icons.view_column_outlined;
      case 'view_stream_outlined':
        return Icons.view_stream_outlined;
      case 'view_comfy_outlined':
        return Icons.view_comfy_outlined;
      case 'view_compact_outlined':
        return Icons.view_compact_outlined;
      case 'view_sidebar_outlined':
        return Icons.view_sidebar_outlined;
      case 'view_array_outlined':
        return Icons.view_array_outlined;
      case 'view_timeline_outlined':
        return Icons.view_timeline_outlined;

      // Data & Files
      case 'import_export':
        return Icons.import_export;
      case 'file_download':
        return Icons.file_download;
      case 'file_upload':
        return Icons.file_upload;
      case 'file_copy':
        return Icons.file_copy;
      case 'file_present':
        return Icons.file_present;
      case 'folder':
        return Icons.folder;
      case 'folder_open':
        return Icons.folder_open;
      case 'folder_shared':
        return Icons.folder_shared;
      case 'folder_special':
        return Icons.folder_special;
      case 'description':
        return Icons.description;
      case 'article':
        return Icons.article;
      case 'text_snippet':
        return Icons.text_snippet;
      case 'note':
        return Icons.note;
      case 'note_add':
        return Icons.note_add;
      case 'edit_note':
        return Icons.edit_note;
      case 'save':
        return Icons.save;
      case 'save_alt':
        return Icons.save_alt;
      case 'print':
        return Icons.print;
      case 'print_disabled':
        return Icons.print_disabled;

      // Communication & Users
      case 'person':
        return Icons.person;
      case 'person_add':
        return Icons.person_add;
      case 'group':
        return Icons.group;
      case 'group_add':
        return Icons.group_add;
      case 'people':
        return Icons.people;
      case 'people_outline':
        return Icons.people_outline;
      case 'account_circle':
        return Icons.account_circle;
      case 'face':
        return Icons.face;
      case 'email':
        return Icons.email;
      case 'phone':
        return Icons.phone;
      case 'message':
        return Icons.message;
      case 'chat':
        return Icons.chat;
      case 'forum':
        return Icons.forum;
      case 'support_agent':
        return Icons.support_agent;
      case 'headset_mic':
        return Icons.headset_mic;
      case 'videocam':
        return Icons.videocam;
      case 'videocam_off':
        return Icons.videocam_off;
      case 'screen_share':
        return Icons.screen_share;
      case 'stop_screen_share':
        return Icons.stop_screen_share;

      // Location & Maps
      case 'location_on':
        return Icons.location_on;
      case 'location_off':
        return Icons.location_off;
      case 'my_location':
        return Icons.my_location;
      case 'place':
        return Icons.place;
      case 'map':
        return Icons.map;
      case 'map_outlined':
        return Icons.map_outlined;
      case 'explore':
        return Icons.explore;
      case 'navigation':
        return Icons.navigation;
      case 'compass_calibration':
        return Icons.compass_calibration;
      case 'directions':
        return Icons.directions;
      case 'directions_car':
        return Icons.directions_car;
      case 'directions_bus':
        return Icons.directions_bus;
      case 'directions_walk':
        return Icons.directions_walk;
      case 'directions_bike':
        return Icons.directions_bike;
      case 'directions_boat':
        return Icons.directions_boat;
      case 'directions_subway':
        return Icons.directions_subway;
      case 'directions_train':
        return Icons.directions_train;
      case 'directions_transit':
        return Icons.directions_transit;

      // Time & Calendar
      case 'access_time':
        return Icons.access_time;
      case 'access_time_filled':
        return Icons.access_time_filled;
      case 'schedule_send':
        return Icons.schedule_send;
      case 'today':
        return Icons.today;
      case 'calendar_today':
        return Icons.calendar_today;
      case 'calendar_month':
        return Icons.calendar_month;
      case 'event':
        return Icons.event;
      case 'event_note':
        return Icons.event_note;
      case 'event_available':
        return Icons.event_available;
      case 'event_busy':
        return Icons.event_busy;
      case 'event_note_outlined':
        return Icons.event_note_outlined;
      case 'event_available_outlined':
        return Icons.event_available_outlined;
      case 'event_busy_outlined':
        return Icons.event_busy_outlined;
      case 'timer_10':
        return Icons.timer_10;
      case 'timer_3':
        return Icons.timer_3;
      case 'timer_off':
        return Icons.timer_off;
      case 'hourglass_empty':
        return Icons.hourglass_empty;
      case 'hourglass_full':
        return Icons.hourglass_full;
      case 'hourglass_bottom':
        return Icons.hourglass_bottom;
      case 'hourglass_top':
        return Icons.hourglass_top;

      // Actions & Controls
      case 'add':
        return Icons.add;
      case 'remove':
        return Icons.remove;
      case 'edit':
        return Icons.edit;
      case 'delete':
        return Icons.delete;
      case 'delete_forever':
        return Icons.delete_forever;
      case 'delete_outline':
        return Icons.delete_outline;
      case 'search':
        return Icons.search;
      case 'filter_list':
        return Icons.filter_list;
      case 'sort':
        return Icons.sort;
      case 'sort_by_alpha':
        return Icons.sort_by_alpha;
      case 'refresh':
        return Icons.refresh;
      case 'update':
        return Icons.update;
      case 'sync':
        return Icons.sync;
      case 'sync_disabled':
        return Icons.sync_disabled;
      case 'download':
        return Icons.download;
      case 'upload':
        return Icons.upload;
      case 'copy':
        return Icons.copy;
      case 'content_copy':
        return Icons.content_copy;
      case 'content_paste':
        return Icons.content_paste;
      case 'content_cut':
        return Icons.content_cut;
      case 'link':
        return Icons.link;
      case 'link_off':
        return Icons.link_off;
      case 'open_in_new':
        return Icons.open_in_new;
      case 'open_in_browser':
        return Icons.open_in_browser;
      case 'open_with':
        return Icons.open_with;
      case 'more_vert':
        return Icons.more_vert;
      case 'more_horiz':
        return Icons.more_horiz;
      case 'menu_open':
        return Icons.menu_open;
      case 'menu_book':
        return Icons.menu_book;

      // Security & Access
      case 'lock':
        return Icons.lock;
      case 'lock_open':
        return Icons.lock_open;
      case 'lock_outline':
        return Icons.lock_outline;
      case 'lock_clock':
        return Icons.lock_clock;
      case 'key':
        return Icons.key;
      case 'vpn_key':
        return Icons.vpn_key;
      case 'security':
        return Icons.security;
      case 'shield':
        return Icons.shield;
      case 'verified_user':
        return Icons.verified_user;
      case 'admin_panel_settings':
        return Icons.admin_panel_settings;
      case 'supervisor_account':
        return Icons.supervisor_account;
      case 'manage_accounts':
        return Icons.manage_accounts;
      case 'account_balance':
        return Icons.account_balance;
      case 'account_balance_wallet':
        return Icons.account_balance_wallet;
      case 'account_circle_outlined':
        return Icons.account_circle_outlined;
      case 'account_tree':
        return Icons.account_tree;
      case 'assignment_ind':
        return Icons.assignment_ind;
      case 'assignment_turned_in':
        return Icons.assignment_turned_in;
      case 'visibility_outlined':
        return Icons.visibility_outlined;
      case 'visibility_off_outlined':
        return Icons.visibility_off_outlined;
      case 'check_circle_outline':
        return Icons.check_circle_outline;
      case 'radio_button_unchecked':
        return Icons.radio_button_unchecked;
      case 'radio_button_checked':
        return Icons.radio_button_checked;
      case 'check_box':
        return Icons.check_box;
      case 'check_box_outline_blank':
        return Icons.check_box_outline_blank;
      case 'indeterminate_check_box':
        return Icons.indeterminate_check_box;
      case 'star':
        return Icons.star;
      case 'star_border':
        return Icons.star_border;
      case 'star_half':
        return Icons.star_half;
      case 'star_outline':
        return Icons.star_outline;
      case 'favorite':
        return Icons.favorite;
      case 'favorite_border':
        return Icons.favorite_border;
      case 'favorite_outline':
        return Icons.favorite_outline;
      case 'thumb_up':
        return Icons.thumb_up;
      case 'thumb_down':
        return Icons.thumb_down;
      case 'flag':
        return Icons.flag;
      case 'flag_outlined':
        return Icons.flag_outlined;
      case 'bookmark':
        return Icons.bookmark;
      case 'bookmark_border':
        return Icons.bookmark_border;
      case 'bookmark_outline':
        return Icons.bookmark_outline;

      // Media & Content
      case 'image':
        return Icons.image;
      case 'image_outlined':
        return Icons.image_outlined;
      case 'photo':
        return Icons.photo;
      case 'photo_outlined':
        return Icons.photo_outlined;
      case 'photo_library':
        return Icons.photo_library;
      case 'photo_library_outlined':
        return Icons.photo_library_outlined;
      case 'camera_alt':
        return Icons.camera_alt;
      case 'camera_alt_outlined':
        return Icons.camera_alt_outlined;
      case 'videocam_outlined':
        return Icons.videocam_outlined;
      case 'music_note':
        return Icons.music_note;
      case 'music_note_outlined':
        return Icons.music_note_outlined;
      case 'play_arrow':
        return Icons.play_arrow;
      case 'pause':
        return Icons.pause;
      case 'stop':
        return Icons.stop;
      case 'skip_next':
        return Icons.skip_next;
      case 'skip_previous':
        return Icons.skip_previous;
      case 'fast_forward':
        return Icons.fast_forward;
      case 'fast_rewind':
        return Icons.fast_rewind;
      case 'volume_up':
        return Icons.volume_up;
      case 'volume_down':
        return Icons.volume_down;
      case 'volume_off':
        return Icons.volume_off;
      case 'volume_mute':
        return Icons.volume_mute;

      // Settings & Configuration
      case 'settings_applications':
        return Icons.settings_applications;
      case 'settings_backup_restore':
        return Icons.settings_backup_restore;
      case 'settings_bluetooth':
        return Icons.settings_bluetooth;
      case 'settings_brightness':
        return Icons.settings_brightness;
      case 'settings_cell':
        return Icons.settings_cell;
      case 'settings_ethernet':
        return Icons.settings_ethernet;
      case 'settings_input_antenna':
        return Icons.settings_input_antenna;
      case 'settings_input_component':
        return Icons.settings_input_component;
      case 'settings_input_composite':
        return Icons.settings_input_composite;
      case 'settings_input_hdmi':
        return Icons.settings_input_hdmi;
      case 'settings_input_svideo':
        return Icons.settings_input_svideo;
      case 'settings_overscan':
        return Icons.settings_overscan;
      case 'settings_phone':
        return Icons.settings_phone;
      case 'settings_power':
        return Icons.settings_power;
      case 'settings_remote':
        return Icons.settings_remote;
      case 'settings_suggest':
        return Icons.settings_suggest;
      case 'settings_system_daydream':
        return Icons.settings_system_daydream;
      case 'settings_voice':
        return Icons.settings_voice;

      // FontAwesome Icons
      case 'weight_scale':
        return FontAwesomeIcons.weightScale.data;
      case 'scale_balanced':
        return FontAwesomeIcons.scaleBalanced.data;
      case 'weight_hanging':
        return FontAwesomeIcons.weightHanging.data;
      case 'bullseye':
        return FontAwesomeIcons.bullseye.data;
      case 'ruler':
        return FontAwesomeIcons.ruler.data;
      case 'anchor':
        return FontAwesomeIcons.anchor.data;
      case 'magnifying_glass_location':
        return FontAwesomeIcons.magnifyingGlassLocation.data;
      case 'slash':
        return FontAwesomeIcons.slash.data;
      case 'dumbbell':
        return FontAwesomeIcons.dumbbell.data;
      case 'play':
        return FontAwesomeIcons.play.data;
      case 'pause_fa':
        return FontAwesomeIcons.pause.data;
      case 'stop_fa':
        return FontAwesomeIcons.stop.data;
      case 'car':
        return FontAwesomeIcons.car.data;
      case 'droplet':
        return FontAwesomeIcons.droplet.data;

      // Additional commonly used FontAwesome icons
      case 'heart':
        return FontAwesomeIcons.heart.data;
      case 'heart_solid':
        return FontAwesomeIcons.solidHeart.data;
      case 'user':
        return FontAwesomeIcons.user.data;
      case 'user_solid':
        return FontAwesomeIcons.solidUser.data;
      case 'envelope':
        return FontAwesomeIcons.envelope.data;
      case 'envelope_solid':
        return FontAwesomeIcons.solidEnvelope.data;
      case 'fa_phone':
        return FontAwesomeIcons.phone.data;
      case 'calendar':
        return FontAwesomeIcons.calendar.data;
      case 'calendar_solid':
        return FontAwesomeIcons.solidCalendar.data;
      case 'clock':
        return FontAwesomeIcons.clock.data;
      case 'clock_solid':
        return FontAwesomeIcons.solidClock.data;
      case 'map_marker':
        return FontAwesomeIcons.locationDot.data;
      case 'globe':
        return FontAwesomeIcons.globe.data;
      case 'cog':
        return FontAwesomeIcons.gear.data;
      case 'bars':
        return FontAwesomeIcons.bars.data;
      case 'times':
        return FontAwesomeIcons.xmark.data;
      case 'check':
        return FontAwesomeIcons.check.data;
      case 'plus':
        return FontAwesomeIcons.plus.data;
      case 'minus':
        return FontAwesomeIcons.minus.data;
      case 'search':
        return FontAwesomeIcons.magnifyingGlass.data;
      case 'edit':
        return FontAwesomeIcons.penToSquare.data;
      case 'trash':
        return FontAwesomeIcons.trash.data;
      case 'download':
        return FontAwesomeIcons.download.data;
      case 'upload':
        return FontAwesomeIcons.upload.data;
      case 'share':
        return FontAwesomeIcons.share.data;
      case 'eye':
        return FontAwesomeIcons.eye.data;
      case 'eye_slash':
        return FontAwesomeIcons.eyeSlash.data;
      case 'lock':
        return FontAwesomeIcons.lock.data;
      case 'unlock':
        return FontAwesomeIcons.unlock.data;
      case 'key':
        return FontAwesomeIcons.key.data;
      case 'shield_alt':
        return FontAwesomeIcons.shieldHalved.data;
      case 'star':
        return FontAwesomeIcons.star.data;
      case 'star_solid':
        return FontAwesomeIcons.solidStar.data;
      case 'thumbs_up':
        return FontAwesomeIcons.thumbsUp.data;
      case 'thumbs_down':
        return FontAwesomeIcons.thumbsDown.data;
      case 'comment':
        return FontAwesomeIcons.comment.data;
      case 'comment_solid':
        return FontAwesomeIcons.solidComment.data;
      case 'bell':
        return FontAwesomeIcons.bell.data;
      case 'bell_solid':
        return FontAwesomeIcons.solidBell.data;
      case 'home':
        return FontAwesomeIcons.house.data;
      case 'chart_bar':
        return FontAwesomeIcons.chartBar.data;
      case 'chart_line':
        return FontAwesomeIcons.chartLine.data;
      case 'chart_pie':
        return FontAwesomeIcons.chartPie.data;
      case 'database':
        return FontAwesomeIcons.database.data;
      case 'server':
        return FontAwesomeIcons.server.data;
      case 'wifi':
        return FontAwesomeIcons.wifi.data;
      case 'bluetooth':
        return FontAwesomeIcons.bluetooth.data;
      case 'usb':
        return FontAwesomeIcons.usb.data;
      case 'plug':
        return FontAwesomeIcons.plug.data;
      case 'battery_full':
        return FontAwesomeIcons.batteryFull.data;
      case 'battery_half':
        return FontAwesomeIcons.batteryHalf.data;
      case 'battery_empty':
        return FontAwesomeIcons.batteryEmpty.data;
      case 'bolt':
        return FontAwesomeIcons.bolt.data;
      case 'fire':
        return FontAwesomeIcons.fire.data;
      case 'snowflake':
        return FontAwesomeIcons.snowflake.data;
      case 'sun':
        return FontAwesomeIcons.sun.data;
      case 'moon':
        return FontAwesomeIcons.moon.data;
      case 'cloud':
        return FontAwesomeIcons.cloud.data;
      case 'cloud_rain':
        return FontAwesomeIcons.cloudRain.data;
      case 'thermometer':
        return FontAwesomeIcons.temperatureHalf.data;
      case 'tachometer':
        return FontAwesomeIcons.gaugeHigh.data;
      case 'wrench':
        return FontAwesomeIcons.wrench.data;
      case 'hammer':
        return FontAwesomeIcons.hammer.data;
      case 'screwdriver':
        return FontAwesomeIcons.screwdriver.data;
      case 'toolbox':
        return FontAwesomeIcons.toolbox.data;
      case 'industry':
        return FontAwesomeIcons.industry.data;
      case 'warehouse_fa':
        return FontAwesomeIcons.warehouse.data;
      case 'warehouse_open':
        return warehouse_open;
      case 'warehouse_open1':
        return warehouse_open1;
      case 'warehouse_open2':
        return warehouse_open2;
      case 'warehouse_closed':
        return warehouse_closed;
      case 'truck':
        return FontAwesomeIcons.truck.data;
      case 'shipping_fast':
        return FontAwesomeIcons.truckFast.data;
      case 'box':
        return FontAwesomeIcons.box.data;
      case 'boxes':
        return FontAwesomeIcons.boxesStacked.data;
      case 'pallet':
        return FontAwesomeIcons.pallet.data;
      case 'pallet_top':
        return pallet_top;
      case 'pallet_stack':
        return pallet_stack;
      case 'clipboard':
        return FontAwesomeIcons.clipboard.data;
      case 'clipboard_list':
        return FontAwesomeIcons.clipboardList.data;
      case 'tasks':
        return FontAwesomeIcons.listCheck.data;
      case 'project_diagram':
        return FontAwesomeIcons.diagramProject.data;
      case 'sitemap':
        return FontAwesomeIcons.sitemap.data;
      case 'network_wired':
        return FontAwesomeIcons.networkWired.data;
      case 'microchip':
        return FontAwesomeIcons.microchip.data;
      case 'memory':
        return FontAwesomeIcons.memory.data;
      case 'hdd':
        return FontAwesomeIcons.hardDrive.data;
      case 'laptop':
        return FontAwesomeIcons.laptop.data;
      case 'mobile_alt':
        return FontAwesomeIcons.mobileScreenButton.data;
      case 'tablet':
        return FontAwesomeIcons.tablet.data;
      case 'desktop':
        return FontAwesomeIcons.desktop.data;
      case 'tv':
        return FontAwesomeIcons.tv.data;

      // Custom Icon
      case 'baader':
        return baadericon;
      case 'ethercat':
        return ethercaticon;
      default:
        return Icons.help; // fallback icon
    }
  }

  /// Public accessor for icon name lookup.
  static String getIconName(IconData iconData) => _getIconName(iconData);

  // Helper method to get icon name from IconData
  static String _getIconName(IconData iconData) {
    // This is a simplified mapping - you might need to expand this
    // based on your actual icon usage
    final industrial = industrialIconNames[iconData];
    if (industrial != null) return industrial;
    if (iconData == Icons.home) return 'home';
    if (iconData == Icons.settings) return 'settings';
    if (iconData == Icons.dashboard) return 'dashboard';
    if (iconData == Icons.menu) return 'menu';
    if (iconData == Icons.close) return 'close';
    if (iconData == Icons.arrow_back) return 'arrow_back';
    if (iconData == Icons.arrow_forward) return 'arrow_forward';
    if (iconData == Icons.expand_more) return 'expand_more';
    if (iconData == Icons.expand_less) return 'expand_less';
    if (iconData == Icons.keyboard_arrow_up) return 'keyboard_arrow_up';
    if (iconData == Icons.keyboard_arrow_down) return 'keyboard_arrow_down';
    if (iconData == Icons.keyboard_arrow_left) return 'keyboard_arrow_left';
    if (iconData == Icons.keyboard_arrow_right) return 'keyboard_arrow_right';
    if (iconData == Icons.analytics) return 'analytics';
    if (iconData == Icons.assessment) return 'assessment';
    if (iconData == Icons.trending_up) return 'trending_up';
    if (iconData == Icons.trending_down) return 'trending_down';
    if (iconData == Icons.show_chart) return 'show_chart';
    if (iconData == Icons.bar_chart) return 'bar_chart';
    if (iconData == Icons.pie_chart) return 'pie_chart';
    if (iconData == Icons.table_chart) return 'table_chart';
    if (iconData == Icons.insert_chart) return 'insert_chart';
    if (iconData == Icons.query_stats) return 'query_stats';
    if (iconData == Icons.insights) return 'insights';
    if (iconData == Icons.data_usage) return 'data_usage';
    if (iconData == Icons.dataset) return 'dataset';
    if (iconData == Icons.storage) return 'storage';
    if (iconData == Icons.cloud) return 'cloud';
    if (iconData == Icons.cloud_download) return 'cloud_download';
    if (iconData == Icons.cloud_upload) return 'cloud_upload';
    if (iconData == Icons.cloud_sync) return 'cloud_sync';
    if (iconData == Icons.monitor) return 'monitor';
    if (iconData == Icons.monitor_heart) return 'monitor_heart';
    if (iconData == Icons.speed) return 'speed';
    if (iconData == Icons.timer) return 'timer';
    if (iconData == Icons.schedule) return 'schedule';
    if (iconData == Icons.alarm) return 'alarm';
    if (iconData == Icons.notifications) return 'notifications';
    if (iconData == Icons.notifications_active) return 'notifications_active';
    if (iconData == Icons.notifications_off) return 'notifications_off';
    if (iconData == Icons.warning) return 'warning';
    if (iconData == Icons.error) return 'error';
    if (iconData == Icons.info) return 'info';
    if (iconData == Icons.check_circle) return 'check_circle';
    if (iconData == Icons.cancel) return 'cancel';
    if (iconData == Icons.help) return 'help';
    if (iconData == Icons.help_outline) return 'help_outline';
    if (iconData == Icons.tune) return 'tune';
    if (iconData == Icons.build) return 'build';
    if (iconData == Icons.engineering) return 'engineering';
    if (iconData == Icons.precision_manufacturing)
      return 'precision_manufacturing';
    if (iconData == Icons.factory) return 'factory';
    if (iconData == Icons.warehouse) return 'warehouse';
    if (iconData == warehouse_open) return 'warehouse_open';
    if (iconData == warehouse_open1) return 'warehouse_open1';
    if (iconData == warehouse_open2) return 'warehouse_open2';
    if (iconData == warehouse_closed) return 'warehouse_closed';
    if (iconData == Icons.inventory) return 'inventory';
    if (iconData == Icons.inventory_2) return 'inventory_2';
    if (iconData == Icons.local_shipping) return 'local_shipping';
    if (iconData == Icons.local_shipping_outlined)
      return 'local_shipping_outlined';
    if (iconData == Icons.construction) return 'construction';
    if (iconData == Icons.handyman) return 'handyman';
    if (iconData == Icons.plumbing) return 'plumbing';
    if (iconData == Icons.electrical_services) return 'electrical_services';
    if (iconData == Icons.architecture) return 'architecture';
    if (iconData == Icons.agriculture) return 'agriculture';
    if (iconData == Icons.forest) return 'forest';
    if (iconData == Icons.park) return 'park';
    if (iconData == Icons.build_circle) return 'build_circle';
    if (iconData == Icons.hardware) return 'hardware';
    if (iconData == Icons.memory) return 'memory';
    if (iconData == Icons.dns) return 'dns';
    if (iconData == Icons.router) return 'router';
    if (iconData == Icons.wifi) return 'wifi';
    if (iconData == Icons.bluetooth) return 'bluetooth';
    if (iconData == Icons.usb) return 'usb';
    if (iconData == Icons.cable) return 'cable';
    if (iconData == Icons.power) return 'power';
    if (iconData == Icons.power_off) return 'power_off';
    if (iconData == Icons.battery_full) return 'battery_full';
    if (iconData == Icons.battery_charging_full) return 'battery_charging_full';
    if (iconData == Icons.battery_alert) return 'battery_alert';
    if (iconData == Icons.bolt) return 'bolt';
    if (iconData == Icons.flash_on) return 'flash_on';
    if (iconData == Icons.electric_bolt) return 'electric_bolt';
    if (iconData == Icons.view_list) return 'view_list';
    if (iconData == Icons.view_module) return 'view_module';
    if (iconData == Icons.view_quilt) return 'view_quilt';
    if (iconData == Icons.view_agenda) return 'view_agenda';
    if (iconData == Icons.view_column) return 'view_column';
    if (iconData == Icons.view_headline) return 'view_headline';
    if (iconData == Icons.view_stream) return 'view_stream';
    if (iconData == Icons.view_week) return 'view_week';
    if (iconData == Icons.view_day) return 'view_day';
    if (iconData == Icons.view_carousel) return 'view_carousel';
    if (iconData == Icons.view_comfy) return 'view_comfy';
    if (iconData == Icons.view_compact) return 'view_compact';
    if (iconData == Icons.view_compact_alt) return 'view_compact_alt';
    if (iconData == Icons.view_cozy) return 'view_cozy';
    if (iconData == Icons.view_in_ar) return 'view_in_ar';
    if (iconData == Icons.view_kanban) return 'view_kanban';
    if (iconData == Icons.view_sidebar) return 'view_sidebar';
    if (iconData == Icons.view_timeline) return 'view_timeline';
    if (iconData == Icons.view_array) return 'view_array';
    if (iconData == Icons.view_comfortable) return 'view_comfortable';
    if (iconData == Icons.view_day_outlined) return 'view_day_outlined';
    if (iconData == Icons.view_week_outlined) return 'view_week_outlined';
    if (iconData == Icons.view_headline_outlined)
      return 'view_headline_outlined';
    if (iconData == Icons.view_carousel_outlined)
      return 'view_carousel_outlined';
    if (iconData == Icons.view_column_outlined) return 'view_column_outlined';
    if (iconData == Icons.view_stream_outlined) return 'view_stream_outlined';
    if (iconData == Icons.view_comfy_outlined) return 'view_comfy_outlined';
    if (iconData == Icons.view_compact_outlined) return 'view_compact_outlined';
    if (iconData == Icons.view_sidebar_outlined) return 'view_sidebar_outlined';
    if (iconData == Icons.view_array_outlined) return 'view_array_outlined';
    if (iconData == Icons.view_timeline_outlined)
      return 'view_timeline_outlined';
    if (iconData == Icons.import_export) return 'import_export';
    if (iconData == Icons.file_download) return 'file_download';
    if (iconData == Icons.file_upload) return 'file_upload';
    if (iconData == Icons.file_copy) return 'file_copy';
    if (iconData == Icons.file_present) return 'file_present';
    if (iconData == Icons.folder) return 'folder';
    if (iconData == Icons.folder_open) return 'folder_open';
    if (iconData == Icons.folder_shared) return 'folder_shared';
    if (iconData == Icons.folder_special) return 'folder_special';
    if (iconData == Icons.description) return 'description';
    if (iconData == Icons.article) return 'article';
    if (iconData == Icons.text_snippet) return 'text_snippet';
    if (iconData == Icons.note) return 'note';
    if (iconData == Icons.note_add) return 'note_add';
    if (iconData == Icons.edit_note) return 'edit_note';
    if (iconData == Icons.save) return 'save';
    if (iconData == Icons.save_alt) return 'save_alt';
    if (iconData == Icons.print) return 'print';
    if (iconData == Icons.print_disabled) return 'print_disabled';
    if (iconData == Icons.person) return 'person';
    if (iconData == Icons.person_add) return 'person_add';
    if (iconData == Icons.group) return 'group';
    if (iconData == Icons.group_add) return 'group_add';
    if (iconData == Icons.people) return 'people';
    if (iconData == Icons.people_outline) return 'people_outline';
    if (iconData == Icons.account_circle) return 'account_circle';
    if (iconData == Icons.face) return 'face';
    if (iconData == Icons.email) return 'email';
    if (iconData == Icons.phone) return 'phone';
    if (iconData == Icons.message) return 'message';
    if (iconData == Icons.chat) return 'chat';
    if (iconData == Icons.forum) return 'forum';
    if (iconData == Icons.support_agent) return 'support_agent';
    if (iconData == Icons.headset_mic) return 'headset_mic';
    if (iconData == Icons.videocam) return 'videocam';
    if (iconData == Icons.videocam_off) return 'videocam_off';
    if (iconData == Icons.screen_share) return 'screen_share';
    if (iconData == Icons.stop_screen_share) return 'stop_screen_share';
    if (iconData == Icons.location_on) return 'location_on';
    if (iconData == Icons.location_off) return 'location_off';
    if (iconData == Icons.my_location) return 'my_location';
    if (iconData == Icons.place) return 'place';
    if (iconData == Icons.map) return 'map';
    if (iconData == Icons.map_outlined) return 'map_outlined';
    if (iconData == Icons.explore) return 'explore';
    if (iconData == Icons.navigation) return 'navigation';
    if (iconData == Icons.compass_calibration) return 'compass_calibration';
    if (iconData == Icons.directions) return 'directions';
    if (iconData == Icons.directions_car) return 'directions_car';
    if (iconData == Icons.directions_bus) return 'directions_bus';
    if (iconData == Icons.directions_walk) return 'directions_walk';
    if (iconData == Icons.directions_bike) return 'directions_bike';
    if (iconData == Icons.directions_boat) return 'directions_boat';
    if (iconData == Icons.directions_subway) return 'directions_subway';
    if (iconData == Icons.directions_train) return 'directions_train';
    if (iconData == Icons.directions_transit) return 'directions_transit';
    if (iconData == Icons.access_time) return 'access_time';
    if (iconData == Icons.access_time_filled) return 'access_time_filled';
    if (iconData == Icons.schedule) return 'schedule';
    if (iconData == Icons.schedule_send) return 'schedule_send';
    if (iconData == Icons.today) return 'today';
    if (iconData == Icons.calendar_today) return 'calendar_today';
    if (iconData == Icons.calendar_month) return 'calendar_month';
    if (iconData == Icons.event) return 'event';
    if (iconData == Icons.event_note) return 'event_note';
    if (iconData == Icons.event_available) return 'event_available';
    if (iconData == Icons.event_busy) return 'event_busy';
    if (iconData == Icons.event_note_outlined) return 'event_note_outlined';
    if (iconData == Icons.event_available_outlined)
      return 'event_available_outlined';
    if (iconData == Icons.event_busy_outlined) return 'event_busy_outlined';
    if (iconData == Icons.timer) return 'timer';
    if (iconData == Icons.timer_10) return 'timer_10';
    if (iconData == Icons.timer_3) return 'timer_3';
    if (iconData == Icons.timer_off) return 'timer_off';
    if (iconData == Icons.hourglass_empty) return 'hourglass_empty';
    if (iconData == Icons.hourglass_full) return 'hourglass_full';
    if (iconData == Icons.hourglass_bottom) return 'hourglass_bottom';
    if (iconData == Icons.hourglass_top) return 'hourglass_top';
    if (iconData == Icons.remove) return 'remove';
    if (iconData == Icons.delete_forever) return 'delete_forever';
    if (iconData == Icons.delete_outline) return 'delete_outline';
    if (iconData == Icons.sort_by_alpha) return 'sort_by_alpha';
    if (iconData == Icons.sync_disabled) return 'sync_disabled';
    if (iconData == Icons.copy) return 'copy';
    if (iconData == Icons.content_copy) return 'content_copy';
    if (iconData == Icons.content_paste) return 'content_paste';
    if (iconData == Icons.content_cut) return 'content_cut';
    if (iconData == Icons.link) return 'link';
    if (iconData == Icons.link_off) return 'link_off';
    if (iconData == Icons.open_in_new) return 'open_in_new';
    if (iconData == Icons.open_in_browser) return 'open_in_browser';
    if (iconData == Icons.open_with) return 'open_with';
    if (iconData == Icons.more_vert) return 'more_vert';
    if (iconData == Icons.more_horiz) return 'more_horiz';
    if (iconData == Icons.menu_open) return 'menu_open';
    if (iconData == Icons.menu_book) return 'menu_book';
    if (iconData == Icons.lock_outline) return 'lock_outline';
    if (iconData == Icons.lock_clock) return 'lock_clock';
    if (iconData == Icons.vpn_key) return 'vpn_key';
    if (iconData == Icons.shield) return 'shield';
    if (iconData == Icons.verified_user) return 'verified_user';
    if (iconData == Icons.supervisor_account) return 'supervisor_account';
    if (iconData == Icons.manage_accounts) return 'manage_accounts';
    if (iconData == Icons.account_balance) return 'account_balance';
    if (iconData == Icons.account_balance_wallet)
      return 'account_balance_wallet';
    if (iconData == Icons.account_circle_outlined)
      return 'account_circle_outlined';
    if (iconData == Icons.account_tree) return 'account_tree';
    if (iconData == Icons.assignment_ind) return 'assignment_ind';
    if (iconData == Icons.assignment_turned_in) return 'assignment_turned_in';

    // Status & Indicators
    if (iconData == Icons.visibility) return 'visibility';
    if (iconData == Icons.visibility_off) return 'visibility_off';
    if (iconData == Icons.visibility_outlined) return 'visibility_outlined';
    if (iconData == Icons.visibility_off_outlined)
      return 'visibility_off_outlined';
    if (iconData == Icons.check) return 'check';
    if (iconData == Icons.check_circle_outline) return 'check_circle_outline';
    if (iconData == Icons.radio_button_unchecked)
      return 'radio_button_unchecked';
    if (iconData == Icons.radio_button_checked) return 'radio_button_checked';
    if (iconData == Icons.check_box) return 'check_box';
    if (iconData == Icons.check_box_outline_blank)
      return 'check_box_outline_blank';
    if (iconData == Icons.indeterminate_check_box)
      return 'indeterminate_check_box';
    if (iconData == Icons.star_border) return 'star_border';
    if (iconData == Icons.star_half) return 'star_half';
    if (iconData == Icons.star_outline) return 'star_outline';
    if (iconData == Icons.favorite_border) return 'favorite_border';
    if (iconData == Icons.favorite_outline) return 'favorite_outline';
    if (iconData == Icons.thumb_up) return 'thumb_up';
    if (iconData == Icons.thumb_down) return 'thumb_down';
    if (iconData == Icons.flag) return 'flag';
    if (iconData == Icons.flag_outlined) return 'flag_outlined';
    if (iconData == Icons.bookmark) return 'bookmark';
    if (iconData == Icons.bookmark_border) return 'bookmark_border';
    if (iconData == Icons.bookmark_outline) return 'bookmark_outline';

    // Media & Content
    if (iconData == Icons.image) return 'image';
    if (iconData == Icons.image_outlined) return 'image_outlined';
    if (iconData == Icons.photo) return 'photo';
    if (iconData == Icons.photo_outlined) return 'photo_outlined';
    if (iconData == Icons.photo_library) return 'photo_library';
    if (iconData == Icons.photo_library_outlined)
      return 'photo_library_outlined';
    if (iconData == Icons.camera_alt) return 'camera_alt';
    if (iconData == Icons.camera_alt_outlined) return 'camera_alt_outlined';
    if (iconData == Icons.videocam_outlined) return 'videocam_outlined';
    if (iconData == Icons.music_note) return 'music_note';
    if (iconData == Icons.music_note_outlined) return 'music_note_outlined';
    if (iconData == Icons.play_arrow) return 'play_arrow';
    if (iconData == Icons.pause) return 'pause';
    if (iconData == Icons.stop) return 'stop';
    if (iconData == Icons.skip_next) return 'skip_next';
    if (iconData == Icons.skip_previous) return 'skip_previous';
    if (iconData == Icons.fast_forward) return 'fast_forward';
    if (iconData == Icons.fast_rewind) return 'fast_rewind';
    if (iconData == Icons.volume_up) return 'volume_up';
    if (iconData == Icons.volume_down) return 'volume_down';
    if (iconData == Icons.volume_off) return 'volume_off';
    if (iconData == Icons.volume_mute) return 'volume_mute';

    // Settings & Configuration
    if (iconData == Icons.settings_applications) return 'settings_applications';
    if (iconData == Icons.settings_backup_restore)
      return 'settings_backup_restore';
    if (iconData == Icons.settings_bluetooth) return 'settings_bluetooth';
    if (iconData == Icons.settings_brightness) return 'settings_brightness';
    if (iconData == Icons.settings_cell) return 'settings_cell';
    if (iconData == Icons.settings_ethernet) return 'settings_ethernet';
    if (iconData == Icons.settings_input_antenna)
      return 'settings_input_antenna';
    if (iconData == Icons.settings_input_component)
      return 'settings_input_component';
    if (iconData == Icons.settings_input_composite)
      return 'settings_input_composite';
    if (iconData == Icons.settings_input_hdmi) return 'settings_input_hdmi';
    if (iconData == Icons.settings_input_svideo) return 'settings_input_svideo';
    if (iconData == Icons.settings_overscan) return 'settings_overscan';
    if (iconData == Icons.settings_phone) return 'settings_phone';
    if (iconData == Icons.settings_power) return 'settings_power';
    if (iconData == Icons.settings_remote) return 'settings_remote';
    if (iconData == Icons.settings_suggest) return 'settings_suggest';
    if (iconData == Icons.settings_system_daydream)
      return 'settings_system_daydream';
    if (iconData == Icons.settings_voice) return 'settings_voice';

    // FontAwesome Icons
    if (iconData == FontAwesomeIcons.weightScale.data) return 'weight_scale';
    if (iconData == FontAwesomeIcons.scaleBalanced.data) return 'scale_balanced';
    if (iconData == FontAwesomeIcons.weightHanging.data) return 'weight_hanging';
    if (iconData == FontAwesomeIcons.bullseye.data) return 'bullseye';
    if (iconData == FontAwesomeIcons.ruler.data) return 'ruler';
    if (iconData == FontAwesomeIcons.anchor.data) return 'anchor';
    if (iconData == FontAwesomeIcons.magnifyingGlassLocation.data)
      return 'magnifying_glass_location';
    if (iconData == FontAwesomeIcons.slash.data) return 'slash';
    if (iconData == FontAwesomeIcons.dumbbell.data) return 'dumbbell';
    if (iconData == FontAwesomeIcons.play.data) return 'play';
    if (iconData == FontAwesomeIcons.pause.data) return 'pause_fa';
    if (iconData == FontAwesomeIcons.stop.data) return 'stop_fa';
    if (iconData == FontAwesomeIcons.car.data) return 'car';
    if (iconData == FontAwesomeIcons.droplet.data) return 'droplet';

    // Additional commonly used FontAwesome icons
    if (iconData == FontAwesomeIcons.heart.data) return 'heart';
    if (iconData == FontAwesomeIcons.solidHeart.data) return 'heart_solid';
    if (iconData == FontAwesomeIcons.user.data) return 'user';
    if (iconData == FontAwesomeIcons.solidUser.data) return 'user_solid';
    if (iconData == FontAwesomeIcons.envelope.data) return 'envelope';
    if (iconData == FontAwesomeIcons.solidEnvelope.data) return 'envelope_solid';
    if (iconData == FontAwesomeIcons.phone.data) return 'fa_phone';
    if (iconData == FontAwesomeIcons.calendar.data) return 'calendar';
    if (iconData == FontAwesomeIcons.solidCalendar.data) return 'calendar_solid';
    if (iconData == FontAwesomeIcons.clock.data) return 'clock';
    if (iconData == FontAwesomeIcons.solidClock.data) return 'clock_solid';
    if (iconData == FontAwesomeIcons.locationDot.data) return 'map_marker';
    if (iconData == FontAwesomeIcons.globe.data) return 'globe';
    if (iconData == FontAwesomeIcons.gear.data) return 'cog';
    if (iconData == FontAwesomeIcons.bars.data) return 'bars';
    if (iconData == FontAwesomeIcons.xmark.data) return 'times';
    if (iconData == FontAwesomeIcons.check.data) return 'check';
    if (iconData == FontAwesomeIcons.plus.data) return 'plus';
    if (iconData == FontAwesomeIcons.minus.data) return 'minus';
    if (iconData == FontAwesomeIcons.magnifyingGlass.data) return 'search';
    if (iconData == FontAwesomeIcons.penToSquare.data) return 'edit';
    if (iconData == FontAwesomeIcons.trash.data) return 'trash';
    if (iconData == FontAwesomeIcons.download.data) return 'download';
    if (iconData == FontAwesomeIcons.upload.data) return 'upload';
    if (iconData == FontAwesomeIcons.share.data) return 'share';
    if (iconData == FontAwesomeIcons.eye.data) return 'eye';
    if (iconData == FontAwesomeIcons.eyeSlash.data) return 'eye_slash';
    if (iconData == FontAwesomeIcons.lock.data) return 'lock';
    if (iconData == FontAwesomeIcons.unlock.data) return 'unlock';
    if (iconData == FontAwesomeIcons.key.data) return 'key';
    if (iconData == FontAwesomeIcons.shieldHalved.data) return 'shield_alt';
    if (iconData == FontAwesomeIcons.star.data) return 'star';
    if (iconData == FontAwesomeIcons.solidStar.data) return 'star_solid';
    if (iconData == FontAwesomeIcons.thumbsUp.data) return 'thumbs_up';
    if (iconData == FontAwesomeIcons.thumbsDown.data) return 'thumbs_down';
    if (iconData == FontAwesomeIcons.comment.data) return 'comment';
    if (iconData == FontAwesomeIcons.solidComment.data) return 'comment_solid';
    if (iconData == FontAwesomeIcons.bell.data) return 'bell';
    if (iconData == FontAwesomeIcons.solidBell.data) return 'bell_solid';
    if (iconData == FontAwesomeIcons.house.data) return 'home';
    if (iconData == FontAwesomeIcons.chartBar.data) return 'chart_bar';
    if (iconData == FontAwesomeIcons.chartLine.data) return 'chart_line';
    if (iconData == FontAwesomeIcons.chartPie.data) return 'chart_pie';
    if (iconData == FontAwesomeIcons.database.data) return 'database';
    if (iconData == FontAwesomeIcons.server.data) return 'server';
    if (iconData == FontAwesomeIcons.wifi.data) return 'wifi';
    if (iconData == FontAwesomeIcons.bluetooth.data) return 'bluetooth';
    if (iconData == FontAwesomeIcons.usb.data) return 'usb';
    if (iconData == FontAwesomeIcons.plug.data) return 'plug';
    if (iconData == FontAwesomeIcons.batteryFull.data) return 'battery_full';
    if (iconData == FontAwesomeIcons.batteryHalf.data) return 'battery_half';
    if (iconData == FontAwesomeIcons.batteryEmpty.data) return 'battery_empty';
    if (iconData == FontAwesomeIcons.bolt.data) return 'bolt';
    if (iconData == FontAwesomeIcons.fire.data) return 'fire';
    if (iconData == FontAwesomeIcons.snowflake.data) return 'snowflake';
    if (iconData == FontAwesomeIcons.sun.data) return 'sun';
    if (iconData == FontAwesomeIcons.moon.data) return 'moon';
    if (iconData == FontAwesomeIcons.cloud.data) return 'cloud';
    if (iconData == FontAwesomeIcons.cloudRain.data) return 'cloud_rain';
    if (iconData == FontAwesomeIcons.temperatureHalf.data) return 'thermometer';
    if (iconData == FontAwesomeIcons.gaugeHigh.data) return 'tachometer';
    if (iconData == FontAwesomeIcons.wrench.data) return 'wrench';
    if (iconData == FontAwesomeIcons.hammer.data) return 'hammer';
    if (iconData == FontAwesomeIcons.screwdriver.data) return 'screwdriver';
    if (iconData == FontAwesomeIcons.toolbox.data) return 'toolbox';
    if (iconData == FontAwesomeIcons.industry.data) return 'industry';
    if (iconData == FontAwesomeIcons.warehouse.data) return 'warehouse_fa';
    if (iconData == warehouse_open) return 'warehouse_open';
    if (iconData == warehouse_open1) return 'warehouse_open1';
    if (iconData == warehouse_open2) return 'warehouse_open2';
    if (iconData == warehouse_closed) return 'warehouse_closed';
    if (iconData == FontAwesomeIcons.truck.data) return 'truck';
    if (iconData == FontAwesomeIcons.truckFast.data) return 'shipping_fast';
    if (iconData == FontAwesomeIcons.box.data) return 'box';
    if (iconData == FontAwesomeIcons.boxesStacked.data) return 'boxes';
    if (iconData == FontAwesomeIcons.pallet.data) return 'pallet';
    if (iconData == pallet_top) return 'pallet_top';
    if (iconData == pallet_stack) return 'pallet_stack';
    if (iconData == FontAwesomeIcons.clipboard.data) return 'clipboard';
    if (iconData == FontAwesomeIcons.clipboardList.data) return 'clipboard_list';
    if (iconData == FontAwesomeIcons.listCheck.data) return 'tasks';
    if (iconData == FontAwesomeIcons.diagramProject.data) return 'project_diagram';
    if (iconData == FontAwesomeIcons.sitemap.data) return 'sitemap';
    if (iconData == FontAwesomeIcons.networkWired.data) return 'network_wired';
    if (iconData == FontAwesomeIcons.microchip.data) return 'microchip';
    if (iconData == FontAwesomeIcons.memory.data) return 'memory';
    if (iconData == FontAwesomeIcons.hardDrive.data) return 'hdd';
    if (iconData == FontAwesomeIcons.laptop.data) return 'laptop';
    if (iconData == FontAwesomeIcons.mobileScreenButton.data) return 'mobile_alt';
    if (iconData == FontAwesomeIcons.tablet.data) return 'tablet';
    if (iconData == FontAwesomeIcons.desktop.data) return 'desktop';
    if (iconData == FontAwesomeIcons.tv.data) return 'tv';

    // Custom Icon
    if (iconData == baadericon) return 'baader';
    if (iconData == ethercaticon) return 'ethercat';
    return 'help'; // fallback
  }
}

final List<IconData> iconList = <IconData>[
  // Navigation & Basic UI
  Icons.home,
  Icons.settings,
  Icons.dashboard,
  Icons.menu,
  Icons.close,
  Icons.arrow_back,
  Icons.arrow_forward,
  Icons.expand_more,
  Icons.expand_less,
  Icons.keyboard_arrow_up,
  Icons.keyboard_arrow_down,
  Icons.keyboard_arrow_left,
  Icons.keyboard_arrow_right,

  // Analytics & Data
  Icons.analytics,
  Icons.assessment,
  Icons.trending_up,
  Icons.trending_down,
  Icons.show_chart,
  Icons.bar_chart,
  Icons.pie_chart,
  Icons.table_chart,
  Icons.insert_chart,
  Icons.query_stats,
  Icons.insights,
  Icons.data_usage,
  Icons.dataset,
  Icons.storage,
  Icons.cloud,
  Icons.cloud_download,
  Icons.cloud_upload,
  Icons.cloud_sync,
  Icons.assessment,
  Icons.trending_up,
  Icons.show_chart,
  Icons.bar_chart,
  Icons.pie_chart,
  Icons.table_chart,

  // Monitoring & Control
  Icons.monitor,
  Icons.monitor_heart,
  Icons.speed,
  Icons.timer,
  Icons.schedule,
  Icons.alarm,
  Icons.notifications,
  Icons.notifications_active,
  Icons.notifications_off,
  Icons.warning,
  Icons.error,
  Icons.info,
  Icons.check_circle,
  Icons.cancel,
  Icons.help,
  Icons.help_outline,

  // Engineering & Manufacturing
  Icons.tune,
  Icons.build,
  Icons.engineering,
  Icons.precision_manufacturing,
  Icons.factory,
  Icons.warehouse,
  Icons.inventory,
  Icons.inventory_2,
  Icons.local_shipping,
  Icons.local_shipping_outlined,
  Icons.construction,
  Icons.handyman,
  Icons.plumbing,
  Icons.electrical_services,
  Icons.architecture,
  Icons.agriculture,
  Icons.forest,
  Icons.park,

  // Tools & Equipment
  Icons.build_circle,
  Icons.hardware,
  Icons.memory,
  Icons.storage,
  Icons.dns,
  Icons.router,
  Icons.wifi,
  Icons.bluetooth,
  Icons.usb,
  Icons.cable,
  Icons.power,
  Icons.power_off,
  Icons.battery_full,
  Icons.battery_charging_full,
  Icons.battery_alert,
  Icons.bolt,
  Icons.flash_on,
  Icons.electric_bolt,

  // View & Display
  Icons.view_list,
  Icons.view_module,
  Icons.view_quilt,
  Icons.view_agenda,
  Icons.view_column,
  Icons.view_headline,
  Icons.view_stream,
  Icons.view_week,
  Icons.view_day,
  Icons.view_carousel,
  Icons.view_comfy,
  Icons.view_compact,
  Icons.view_compact_alt,
  Icons.view_cozy,
  Icons.view_in_ar,
  Icons.view_kanban,
  Icons.view_sidebar,
  Icons.view_timeline,
  Icons.view_array,
  Icons.view_comfortable,
  Icons.view_day_outlined,
  Icons.view_week_outlined,
  Icons.view_headline_outlined,
  Icons.view_carousel_outlined,
  Icons.view_column_outlined,
  Icons.view_stream_outlined,
  Icons.view_comfy_outlined,
  Icons.view_compact_outlined,
  Icons.view_sidebar_outlined,
  Icons.view_array_outlined,
  Icons.view_timeline_outlined,

  // Data & Files
  Icons.import_export,
  Icons.file_download,
  Icons.file_upload,
  Icons.file_copy,
  Icons.file_present,
  Icons.folder,
  Icons.folder_open,
  Icons.folder_shared,
  Icons.folder_special,
  Icons.description,
  Icons.article,
  Icons.text_snippet,
  Icons.note,
  Icons.note_add,
  Icons.edit_note,
  Icons.save,
  Icons.save_alt,
  Icons.print,
  Icons.print_disabled,

  // Communication & Users
  Icons.person,
  Icons.person_add,
  Icons.group,
  Icons.group_add,
  Icons.people,
  Icons.people_outline,
  Icons.account_circle,
  Icons.face,
  Icons.email,
  Icons.phone,
  Icons.message,
  Icons.chat,
  Icons.forum,
  Icons.support_agent,
  Icons.headset_mic,
  Icons.videocam,
  Icons.videocam_off,
  Icons.screen_share,
  Icons.stop_screen_share,

  // Location & Maps
  Icons.location_on,
  Icons.location_off,
  Icons.my_location,
  Icons.place,
  Icons.map,
  Icons.map_outlined,
  Icons.explore,
  Icons.navigation,
  Icons.compass_calibration,
  Icons.directions,
  Icons.directions_car,
  Icons.directions_bus,
  Icons.directions_walk,
  Icons.directions_bike,
  Icons.directions_boat,
  Icons.directions_subway,
  Icons.directions_train,
  Icons.directions_transit,

  // Time & Calendar
  Icons.access_time,
  Icons.access_time_filled,
  Icons.schedule,
  Icons.schedule_send,
  Icons.today,
  Icons.calendar_today,
  Icons.calendar_month,
  Icons.event,
  Icons.event_note,
  Icons.event_available,
  Icons.event_busy,
  Icons.event_note_outlined,
  Icons.event_available_outlined,
  Icons.event_busy_outlined,
  Icons.timer,
  Icons.timer_10,
  Icons.timer_3,
  Icons.timer_off,
  Icons.hourglass_empty,
  Icons.hourglass_full,
  Icons.hourglass_bottom,
  Icons.hourglass_top,

  // Actions & Controls
  Icons.add,
  Icons.remove,
  Icons.edit,
  Icons.delete,
  Icons.delete_forever,
  Icons.delete_outline,
  Icons.search,
  Icons.filter_list,
  Icons.sort,
  Icons.sort_by_alpha,
  Icons.refresh,
  Icons.update,
  Icons.sync,
  Icons.sync_disabled,
  Icons.download,
  Icons.upload,
  Icons.copy,
  Icons.content_copy,
  Icons.content_paste,
  Icons.content_cut,
  Icons.link,
  Icons.link_off,
  Icons.open_in_new,
  Icons.open_in_browser,
  Icons.open_with,
  Icons.more_vert,
  Icons.more_horiz,
  Icons.menu_open,
  Icons.menu_book,

  // Security & Access
  Icons.lock,
  Icons.lock_open,
  Icons.lock_outline,
  Icons.lock_clock,
  Icons.key,
  Icons.vpn_key,
  Icons.security,
  Icons.shield,
  Icons.verified_user,
  Icons.admin_panel_settings,
  Icons.supervisor_account,
  Icons.manage_accounts,
  Icons.account_balance,
  Icons.account_balance_wallet,
  Icons.account_circle_outlined,
  Icons.account_tree,
  Icons.assignment_ind,
  Icons.assignment_turned_in,

  // Status & Indicators
  Icons.visibility,
  Icons.visibility_off,
  Icons.visibility_outlined,
  Icons.visibility_off_outlined,
  Icons.check,
  Icons.check_circle_outline,
  Icons.radio_button_unchecked,
  Icons.radio_button_checked,
  Icons.check_box,
  Icons.check_box_outline_blank,
  Icons.indeterminate_check_box,
  Icons.star,
  Icons.star_border,
  Icons.star_half,
  Icons.star_outline,
  Icons.favorite,
  Icons.favorite_border,
  Icons.favorite_outline,
  Icons.thumb_up,
  Icons.thumb_down,
  Icons.flag,
  Icons.flag_outlined,
  Icons.bookmark,
  Icons.bookmark_border,
  Icons.bookmark_outline,

  // Media & Content
  Icons.image,
  Icons.image_outlined,
  Icons.photo,
  Icons.photo_outlined,
  Icons.photo_library,
  Icons.photo_library_outlined,
  Icons.camera_alt,
  Icons.camera_alt_outlined,
  Icons.videocam_outlined,
  Icons.music_note,
  Icons.music_note_outlined,
  Icons.play_arrow,
  Icons.pause,
  Icons.stop,
  Icons.skip_next,
  Icons.skip_previous,
  Icons.fast_forward,
  Icons.fast_rewind,
  Icons.volume_up,
  Icons.volume_down,
  Icons.volume_off,
  Icons.volume_mute,

  // Settings & Configuration
  Icons.settings_applications,
  Icons.settings_backup_restore,
  Icons.settings_bluetooth,
  Icons.settings_brightness,
  Icons.settings_cell,
  Icons.settings_ethernet,
  Icons.settings_input_antenna,
  Icons.settings_input_component,
  Icons.settings_input_composite,
  Icons.settings_input_hdmi,
  Icons.settings_input_svideo,
  Icons.settings_overscan,
  Icons.settings_phone,
  Icons.settings_power,
  Icons.settings_remote,
  Icons.settings_suggest,
  Icons.settings_system_daydream,
  Icons.settings_voice,

  // FontAwesome Icons
  FontAwesomeIcons.weightScale.data,
  FontAwesomeIcons.scaleBalanced.data,
  FontAwesomeIcons.weightHanging.data,
  FontAwesomeIcons.bullseye.data,
  FontAwesomeIcons.ruler.data,
  FontAwesomeIcons.anchor.data,
  FontAwesomeIcons.magnifyingGlassLocation.data,
  FontAwesomeIcons.slash.data,
  FontAwesomeIcons.dumbbell.data,
  FontAwesomeIcons.play.data,
  FontAwesomeIcons.pause.data,
  FontAwesomeIcons.stop.data,
  FontAwesomeIcons.car.data,
  FontAwesomeIcons.droplet.data,

  // Additional commonly used FontAwesome icons
  FontAwesomeIcons.heart.data,
  FontAwesomeIcons.solidHeart.data,
  FontAwesomeIcons.user.data,
  FontAwesomeIcons.solidUser.data,
  FontAwesomeIcons.envelope.data,
  FontAwesomeIcons.solidEnvelope.data,
  FontAwesomeIcons.phone.data,
  FontAwesomeIcons.calendar.data,
  FontAwesomeIcons.solidCalendar.data,
  FontAwesomeIcons.clock.data,
  FontAwesomeIcons.solidClock.data,
  FontAwesomeIcons.locationDot.data,
  FontAwesomeIcons.globe.data,
  FontAwesomeIcons.gear.data,
  FontAwesomeIcons.bars.data,
  FontAwesomeIcons.xmark.data,
  FontAwesomeIcons.check.data,
  FontAwesomeIcons.plus.data,
  FontAwesomeIcons.minus.data,
  FontAwesomeIcons.magnifyingGlass.data,
  FontAwesomeIcons.penToSquare.data,
  FontAwesomeIcons.trash.data,
  FontAwesomeIcons.download.data,
  FontAwesomeIcons.upload.data,
  FontAwesomeIcons.share.data,
  FontAwesomeIcons.eye.data,
  FontAwesomeIcons.eyeSlash.data,
  FontAwesomeIcons.lock.data,
  FontAwesomeIcons.unlock.data,
  FontAwesomeIcons.key.data,
  FontAwesomeIcons.shieldHalved.data,
  FontAwesomeIcons.star.data,
  FontAwesomeIcons.solidStar.data,
  FontAwesomeIcons.thumbsUp.data,
  FontAwesomeIcons.thumbsDown.data,
  FontAwesomeIcons.comment.data,
  FontAwesomeIcons.solidComment.data,
  FontAwesomeIcons.bell.data,
  FontAwesomeIcons.solidBell.data,
  FontAwesomeIcons.house.data,
  FontAwesomeIcons.chartBar.data,
  FontAwesomeIcons.chartLine.data,
  FontAwesomeIcons.chartPie.data,
  FontAwesomeIcons.database.data,
  FontAwesomeIcons.server.data,
  FontAwesomeIcons.wifi.data,
  FontAwesomeIcons.bluetooth.data,
  FontAwesomeIcons.usb.data,
  FontAwesomeIcons.plug.data,
  FontAwesomeIcons.batteryFull.data,
  FontAwesomeIcons.batteryHalf.data,
  FontAwesomeIcons.batteryEmpty.data,
  FontAwesomeIcons.bolt.data,
  FontAwesomeIcons.fire.data,
  FontAwesomeIcons.snowflake.data,
  FontAwesomeIcons.sun.data,
  FontAwesomeIcons.moon.data,
  FontAwesomeIcons.cloud.data,
  FontAwesomeIcons.cloudRain.data,
  FontAwesomeIcons.temperatureHalf.data,
  FontAwesomeIcons.gaugeHigh.data,
  FontAwesomeIcons.wrench.data,
  FontAwesomeIcons.hammer.data,
  FontAwesomeIcons.screwdriver.data,
  FontAwesomeIcons.toolbox.data,
  FontAwesomeIcons.industry.data,
  FontAwesomeIcons.warehouse.data,
  FontAwesomeIcons.truck.data,
  FontAwesomeIcons.truckFast.data,
  FontAwesomeIcons.box.data,
  FontAwesomeIcons.boxesStacked.data,
  FontAwesomeIcons.pallet.data,
  FontAwesomeIcons.clipboard.data,
  FontAwesomeIcons.clipboardList.data,
  FontAwesomeIcons.listCheck.data,
  FontAwesomeIcons.diagramProject.data,
  FontAwesomeIcons.sitemap.data,
  FontAwesomeIcons.networkWired.data,
  FontAwesomeIcons.microchip.data,
  FontAwesomeIcons.memory.data,
  FontAwesomeIcons.hardDrive.data,
  FontAwesomeIcons.laptop.data,
  FontAwesomeIcons.mobileScreenButton.data,
  FontAwesomeIcons.tablet.data,
  FontAwesomeIcons.desktop.data,
  FontAwesomeIcons.tv.data,

  // Industrial glyphs -- sensors, motors, drives, pumps, I/O. Spliced in
  // whole so a glyph added to the font shows up in the picker with it.
  ...industrialIcons.values,

  // Custom Icon
  baadericon,
  warehouse_open,
  warehouse_open1,
  warehouse_open2,
  warehouse_closed,
  pallet_top,
  pallet_stack,
  ethercaticon,
];
