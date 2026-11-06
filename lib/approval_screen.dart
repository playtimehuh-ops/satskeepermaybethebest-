import 'package:flutter/material.dart';
import 'services.dart';
import 'theme.dart';

class ApprovalScreen extends StatefulWidget {
  const ApprovalScreen({super.key});
  @override State<ApprovalScreen> createState() => _ApprovalScreenState();
}
class _ApprovalScreenState extends State<ApprovalScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  @override void dispose(){ _code.dispose(); super.dispose(); }
  Future<void> _submit() async {
    if (_busy) return;
    setState((){_busy=true;_error=null;});
    try {
      await AuthService.redeemApprovalCode(_code.text);
      if (mounted) setState((){});
    } on AuthException catch(e) { if(mounted) setState(()=>_error=e.message); }
    finally { if(mounted) setState(()=>_busy=false); }
  }
  @override Widget build(BuildContext context) {
    final c=context.c;
    return Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth:420), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children:[
      Text('GainDeep',style:T.title(c).copyWith(fontSize:40)), const SizedBox(height:18),
      Text('Your application is being reviewed',style:T.heading(c)), const SizedBox(height:10),
      Text('Thanks for registering. Account approval usually takes 1–48 hours. We will provide an approval code when your account is ready.',style:T.body(c).copyWith(color:c.muted)),
      const SizedBox(height:30), Text('Have an approval code?',style:T.strong(c)), const SizedBox(height:10),
      TextField(controller:_code,keyboardType:TextInputType.number,maxLength:8,decoration:const InputDecoration(labelText:'8-digit approval code',counterText:'')),
      if(_error!=null) Padding(padding:const EdgeInsets.only(top:12),child:Text(_error!,style:TextStyle(color:c.danger))),
      const SizedBox(height:16), SizedBox(width:double.infinity,child:ElevatedButton(onPressed:_busy?null:_submit,child:Text(_busy?'Checking…':'Submit code'))),
      const SizedBox(height:14), TextButton(onPressed:AuthService.signOut,child:const Text('Log out'))
    ]))))));
  }
}
