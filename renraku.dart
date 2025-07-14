import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:excel/excel.dart'; // Excelパッケージ
import 'package:intl/intl.dart'; // 日付フォーマット用に追加

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '連絡帳アプリ',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: ContactsApp(),
    );
  }
}

class Contact {
  String id;
  String name;
  String organization;
  List<String> phoneNumbers;
  List<String> emails;
  String address;
  String group;
  String memo;
  bool isFavorite;
  DateTime createdAt;

  Contact({
    required this.id,
    required this.name,
    this.organization = '',
    List<String>? phoneNumbers,
    List<String>? emails,
    this.address = '',
    this.group = '',
    this.memo = '',
    this.isFavorite = false,
    DateTime? createdAt,
  }) : phoneNumbers = phoneNumbers ?? [],
       emails = emails ?? [],
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'organization': organization,
    'phoneNumbers': phoneNumbers,
    'emails': emails,
    'address': address,
    'group': group,
    'memo': memo,
    'isFavorite': isFavorite,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
    id: json['id'],
    name: json['name'],
    organization: json['organization'] ?? '',
    phoneNumbers: List<String>.from(json['phoneNumbers'] ?? []),
    emails: List<String>.from(json['emails'] ?? []),
    address: json['address'] ?? '',
    group: json['group'] ?? '',
    memo: json['memo'] ?? '',
    isFavorite: json['isFavorite'] ?? false,
    createdAt: DateTime.parse(json['createdAt']),
  );

  String toVCF() {
    StringBuffer vcf = StringBuffer();
    vcf.writeln('BEGIN:VCARD');
    vcf.writeln('VERSION:3.0');
    vcf.writeln('FN:$name');
    
    // Nフィールド（構造化された名前）を追加して互換性を向上
    // 形式: N:姓;名;ミドルネーム;敬称;接尾辞
    // 簡単のため、ここではFNと同じ値を姓として設定
    List<String> nameParts = name.split(' ');
    String lastName = nameParts.length > 1 ? nameParts.last : name;
    String firstName = nameParts.length > 1 ? nameParts.sublist(0, nameParts.length - 1).join(' ') : '';
    vcf.writeln('N:$lastName;$firstName;;;');

    if (organization.isNotEmpty) vcf.writeln('ORG:$organization');
    for (String phone in phoneNumbers) {
      vcf.writeln('TEL:$phone');
    }
    for (String email in emails) {
      vcf.writeln('EMAIL:$email');
    }
    if (address.isNotEmpty) {
      // ADRフィールドの形式: ADR:POBox;Ext;Street;City;State;Zip;Country
      // ここでは、住所全体をStreet部分に格納
      vcf.writeln('ADR:;;$address;;;;');
    }
    if (memo.isNotEmpty) vcf.writeln('NOTE:$memo');
    // グループをCATEGORIESとして追加
    if (group.isNotEmpty) vcf.writeln('CATEGORIES:$group');
    vcf.writeln('END:VCARD');
    return vcf.toString();
  }

  // VCFパース用のファクトリコンストラクタを更新
  factory Contact.fromVCFString(String vcfBlock) {
    final contact = Contact(id: DateTime.now().millisecondsSinceEpoch.toString(), name: '');
    final lines = vcfBlock.split('\n').map((e) => e.trim()).toList();

    for (var line in lines) {
      if (line.startsWith('FN:')) {
        contact.name = line.substring(3);
      } else if (line.startsWith('N:')) {
        // Nフィールドから名前を抽出（FNがなければ使用）
        if (contact.name.isEmpty) {
          final parts = line.substring(2).split(';');
          if (parts.length >= 2) {
            contact.name = '${parts[1]} ${parts[0]}'.trim(); // 名 姓 の順で結合
          } else {
            contact.name = parts[0].trim();
          }
        }
      } else if (line.startsWith('ORG:')) {
        contact.organization = line.substring(4);
      } else if (line.startsWith('TEL:')) {
        contact.phoneNumbers.add(line.substring(4));
      } else if (line.startsWith('EMAIL:')) {
        contact.emails.add(line.substring(6));
      } else if (line.startsWith('ADR:')) {
        final parts = line.substring(4).split(';');
        // street, city, state, zip, country を結合してaddressに
        if (parts.length >= 3) { // Street以上の情報がある場合
          contact.address = parts.sublist(2).where((e) => e.isNotEmpty).join(', ');
        }
      } else if (line.startsWith('CATEGORIES:')) {
        contact.group = line.substring('CATEGORIES:'.length).trim();
      } else if (line.startsWith('NOTE:')) {
        contact.memo = line.substring(5);
      }
    }
    return contact;
  }
}

class ContactsApp extends StatefulWidget {
  @override
  _ContactsAppState createState() => _ContactsAppState();
}

class _ContactsAppState extends State<ContactsApp> {
  List<Contact> allContacts = [];
  List<Contact> filteredContacts = [];
  String searchQuery = '';
  String selectedFilter = 'すべて';
  String selectedGroup = '';
  String sortBy = '名前順 (昇順)';
  List<String> groups = [];
  
  // 重複電話番号検索用の状態
  bool showDuplicatesView = false; // 重複ビューを表示するかどうか
  Map<String, List<Contact>> duplicatePhoneGroups = {}; // 重複する電話番号ごとの連絡先リスト
  Set<String> selectedDuplicateContactIds = {}; // 重複ビューで削除対象として選択された連絡先のID

  bool _isLoading = false; // ローディング状態管理用

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() { _isLoading = true; }); // ローディング開始
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? contactsJson = prefs.getString('contacts');
    if (contactsJson != null) {
      List<dynamic> contactsList = json.decode(contactsJson);
      setState(() {
        allContacts = contactsList.map((c) => Contact.fromJson(c)).toList();
        _updateFilteredContacts();
        _updateGroups();
      });
    }
    setState(() { _isLoading = false; }); // ローディング終了
  }

  Future<void> _saveContacts() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String contactsJson = json.encode(allContacts.map((c) => c.toJson()).toList());
    await prefs.setString('contacts', contactsJson);
  }

  void _updateFilteredContacts() {
    setState(() {
      filteredContacts = allContacts.where((contact) {
        bool matchesSearch = searchQuery.isEmpty ||
            contact.name.toLowerCase().contains(searchQuery.toLowerCase()) ||
            contact.organization.toLowerCase().contains(searchQuery.toLowerCase()) ||
            contact.phoneNumbers.any((p) => p.contains(searchQuery)) ||
            contact.emails.any((e) => e.toLowerCase().contains(searchQuery.toLowerCase())) ||
            contact.address.toLowerCase().contains(searchQuery.toLowerCase()) ||
            contact.group.toLowerCase().contains(searchQuery.toLowerCase()) ||
            contact.memo.toLowerCase().contains(searchQuery.toLowerCase());

        bool matchesFilter = selectedFilter == 'すべて' ||
            (selectedFilter == '⭐ お気に入り' && contact.isFavorite) ||
            (selectedFilter == 'グループ' && contact.group == selectedGroup);

        return matchesSearch && matchesFilter;
      }).toList();

      _sortContacts();
    });
  }

  void _sortContacts() {
    switch (sortBy) {
      case '名前順 (昇順)':
        filteredContacts.sort((a, b) => a.name.compareTo(b.name));
        break;
      case '名前順 (降順)':
        filteredContacts.sort((a, b) => b.name.compareTo(a.name));
        break;
      case '追加日時 (新しい順)':
        filteredContacts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case '追加日時 (古い順)':
        filteredContacts.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
    }
  }

  void _updateGroups() {
    setState(() {
      groups = allContacts
          .where((c) => c.group.isNotEmpty)
          .map((c) => c.group)
          .toSet()
          .toList();
    });
  }

  Future<void> _importVCF() async {
    // 権限チェック (Android 以外では不要な場合が多いですが、念のため)
    var status = await Permission.storage.request();
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ストレージへのアクセス権限が必要です。')),
      );
      return;
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['vcf'],
      allowMultiple: true,
    );

    if (result != null) {
      setState(() { _isLoading = true; }); // ローディング開始
      int importedCount = 0;
      for (PlatformFile file in result.files) {
        if (file.bytes != null) {
          String content = utf8.decode(file.bytes!); // VCFはUTF-8であることが多い
          
          // VCFブロックごとに分割
          List<String> vcardBlocks = content.split('END:VCARD').where((e) => e.trim().isNotEmpty).map((e) => e + 'END:VCARD').toList();

          for (String block in vcardBlocks) {
            try {
              Contact contact = Contact.fromVCFString(block);
              if (contact.name.isNotEmpty) {
                allContacts.add(contact);
                importedCount++;
              }
            } catch (e) {
              print('VCF解析エラー: $e for block: $block');
            }
          }
        }
      }
      
      await _saveContacts();
      _updateFilteredContacts();
      _updateGroups();
      setState(() { _isLoading = false; }); // ローディング終了
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$importedCount 件の連絡先をVCFファイルから読み込みました。')),
      );
    }
  }

  Future<void> _importExcel() async {
    // 権限チェック
    var status = await Permission.storage.request();
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ストレージへのアクセス権限が必要です。')),
      );
      return;
    }

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
    );

    if (result != null && result.files.single.bytes != null) {
      setState(() { _isLoading = true; }); // ローディング開始
      var bytes = result.files.single.bytes!;
      var excel = Excel.decodeBytes(bytes);
      int importedCount = 0;
      
      for (var table in excel.tables.keys) {
        var sheet = excel.tables[table]!;
        if (sheet.rows.isNotEmpty) {
          var headers = sheet.rows[0].map((cell) => cell?.value?.toString() ?? '').toList();
          
          for (int i = 1; i < sheet.rows.length; i++) {
            var row = sheet.rows[i];
            Contact contact = Contact(
              id: DateTime.now().millisecondsSinceEpoch.toString() + i.toString(),
              name: '',
            );
            
            for (int j = 0; j < headers.length && j < row.length; j++) {
              String header = headers[j].toLowerCase();
              String value = row[j]?.value?.toString() ?? '';
              
              if (header.contains('名前') || header.contains('name')) {
                contact.name = value;
              } else if (header.contains('組織') || header.contains('organization')) {
                contact.organization = value;
              } else if (header.contains('電話') || header.contains('phone')) {
                if (value.isNotEmpty) contact.phoneNumbers.add(value);
              } else if (header.contains('メール') || header.contains('email')) {
                if (value.isNotEmpty) contact.emails.add(value);
              } else if (header.contains('住所') || header.contains('address')) {
                contact.address = value;
              } else if (header.contains('グループ') || header.contains('group')) {
                contact.group = value;
              } else if (header.contains('メモ') || header.contains('memo') || header.contains('note')) {
                contact.memo = value;
              } else if (header.contains('お気に入り') || header.contains('favorite')) {
                contact.isFavorite = value.toLowerCase() == 'true' || value == '1' || value.toLowerCase() == 'はい';
              }
            }
            
            if (contact.name.isNotEmpty) {
              allContacts.add(contact);
              importedCount++;
            }
          }
        }
      }
      
      await _saveContacts();
      _updateFilteredContacts();
      _updateGroups();
      setState(() { _isLoading = false; }); // ローディング終了
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$importedCount 件の連絡先をExcelファイルから読み込みました。')),
      );
    } else {
      setState(() { _isLoading = false; }); // ローディング終了
    }
  }

  void _showAddContactDialog([Contact? contact]) {
    final isEdit = contact != null;
    final nameController = TextEditingController(text: contact?.name ?? '');
    final organizationController = TextEditingController(text: contact?.organization ?? '');
    final addressController = TextEditingController(text: contact?.address ?? '');
    final groupController = TextEditingController(text: contact?.group ?? '');
    final memoController = TextEditingController(text: contact?.memo ?? '');
    
    List<TextEditingController> phoneControllers = [];
    List<TextEditingController> emailControllers = [];
    
    if (isEdit) {
      for (String phone in contact!.phoneNumbers) {
        phoneControllers.add(TextEditingController(text: phone));
      }
      for (String email in contact.emails) {
        emailControllers.add(TextEditingController(text: email));
      }
    }
    
    // 少なくとも1つの入力フィールドを常に表示
    if (phoneControllers.isEmpty) phoneControllers.add(TextEditingController());
    if (emailControllers.isEmpty) emailControllers.add(TextEditingController());
    
    bool isFavorite = contact?.isFavorite ?? false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEdit ? '連絡先を編集' : '新規連絡先'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(labelText: '名前 *'),
                ),
                TextField(
                  controller: organizationController,
                  decoration: InputDecoration(labelText: '組織'),
                ),
                SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('電話番号', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ...phoneControllers.asMap().entries.map((entry) {
                  int index = entry.key;
                  TextEditingController controller = entry.value;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            decoration: InputDecoration(
                              labelText: '電話番号 ${index + 1}',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 10.0),
                            ),
                            keyboardType: TextInputType.phone,
                          ),
                        ),
                        SizedBox(width: 8),
                        IconButton(
                          icon: Icon(Icons.remove_circle_outline, color: Colors.red),
                          onPressed: phoneControllers.length > 1 ? () {
                            setDialogState(() {
                              controller.dispose(); // コントローラーを破棄
                              phoneControllers.removeAt(index);
                            });
                          } : null,
                        ),
                      ],
                    ),
                  );
                }).toList(),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      setDialogState(() {
                        phoneControllers.add(TextEditingController());
                      });
                    },
                    icon: Icon(Icons.add),
                    label: Text('電話番号を追加'),
                  ),
                ),
                SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('メールアドレス', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ...emailControllers.asMap().entries.map((entry) {
                  int index = entry.key;
                  TextEditingController controller = entry.value;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            decoration: InputDecoration(
                              labelText: 'メールアドレス ${index + 1}',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 10.0),
                            ),
                            keyboardType: TextInputType.emailAddress,
                          ),
                        ),
                        SizedBox(width: 8),
                        IconButton(
                          icon: Icon(Icons.remove_circle_outline, color: Colors.red),
                          onPressed: emailControllers.length > 1 ? () {
                            setDialogState(() {
                              controller.dispose(); // コントローラーを破棄
                              emailControllers.removeAt(index);
                            });
                          } : null,
                        ),
                      ],
                    ),
                  );
                }).toList(),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      setDialogState(() {
                        emailControllers.add(TextEditingController());
                      });
                    },
                    icon: Icon(Icons.add),
                    label: Text('メールアドレスを追加'),
                  ),
                ),
                TextField(
                  controller: addressController,
                  decoration: InputDecoration(labelText: '住所'),
                ),
                TextField(
                  controller: groupController,
                  decoration: InputDecoration(labelText: 'グループ'),
                ),
                TextField(
                  controller: memoController,
                  decoration: InputDecoration(labelText: 'メモ'),
                  maxLines: 3,
                ),
                CheckboxListTile(
                  title: Text('お気に入り'),
                  value: isFavorite,
                  onChanged: (value) {
                    setDialogState(() {
                      isFavorite = value ?? false;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                // ダイアログを閉じる際にコントローラーを破棄
                nameController.dispose();
    
