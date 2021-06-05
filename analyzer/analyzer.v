module analyzer

// it should be imported just to have those C type symbols available
// import tree_sitter

pub enum SymbolKind {
	function
	struct_
	enum_
	typedef
	interface_
	field
	placeholder
	variable
}

pub enum SymbolAccess {
	private
	private_mutable
	public
	public_mutable
	global
}

pub struct ScopeTree {
mut:
	parent &ScopeTree = &ScopeTree(0)
	start_byte u32
	end_byte u32
	symbols map[string]&TypeSymbol
	children []&ScopeTree
}

pub fn (scope &ScopeTree) contains(pos u32) bool {
	return pos >= scope.start_byte && pos <= scope.end_byte
}

pub fn (scope &ScopeTree) innermost(pos u32) &ScopeTree {
	for child_scope in scope.children {
		if child_scope.contains(pos) {
			return child_scope.innermost(pos)
		}
	}

	return unsafe { scope }
}

pub fn (mut scope ScopeTree) register(info &TypeSymbol) {
	scope.symbols[info.name] = info
}

struct Import {
mut:
	resolved bool
pub mut:
	symbols []string
	path string
	mod string
	alias string
}

pub struct Store {
mut:
	imports map[string][]Import
	fs_to_module_names map[string]string
	module_names_to_fs map[string]string
pub mut:
	symbols map[string]&TypeSymbol
	opened_scopes map[string]&ScopeTree
}

pub fn (mut ss Store) find_symbol(name string) &TypeSymbol {
	if name.len == 0 {
		return &TypeSymbol(0)
	}

	typ := ss.symbols[name] or {
		ss.register_symbol(&TypeSymbol{
			name: name
			kind: .placeholder
		}) or { &TypeSymbol(0) }
	}

	return typ
}

pub fn (mut ss Store) register_symbol(info &TypeSymbol) ?&TypeSymbol {
	if info.name in ss.symbols {
		return error('Symbol already exists. (name="${info.name}")')
	}

	ss.symbols[info.name] = info
	return info
}

pub fn (mut ss Store) add_import(dir string, imp Import) {
	mut new_import := Import{ ...imp }
	if new_import.path.len != 0 && !new_import.resolved {
		new_import.resolved = true
	}

	if dir !in ss.imports {
		ss.imports[dir] = []Import{}
	}

	ss.imports[dir] << new_import 
}

[heap]
struct TypeSymbol {
mut:
	name string
	kind SymbolKind
	access SymbolAccess
	range C.TSRange
	parent &TypeSymbol = &TypeSymbol(0)
	return_type &TypeSymbol = &TypeSymbol(0)
	children map[string]&TypeSymbol
	// filepath string
}

pub fn (info &TypeSymbol) str() string {
	typ := if isnil(info.return_type) { 'void' } else { info.return_type.name }
	return '(${info.access} ${info.kind} ${info.name} -> ($typ) ${info.children})'
}

pub fn (infos []&TypeSymbol) str() string {
	return '[' +  infos.map(it.str()).join(', ') + ']'
}

pub fn (mut info TypeSymbol) add_child(mut new_child TypeSymbol) ? {
	if new_child.name in info.children {
		return error('child exists.')
	}

	new_child.parent = info
	info.children[new_child.name] = new_child
}

pub struct Analyzer {
pub mut:
	cur_file_path string
	cursor   C.TSTreeCursor
	src_text []byte
	store &Store = &Store(0)
	scope &ScopeTree = &ScopeTree(0)
}

pub fn (mut an Analyzer) get_scope(node C.TSNode) &ScopeTree {
	if node.get_type() == 'source_file' {
		if an.cur_file_path !in an.store.opened_scopes {
			an.store.opened_scopes[an.cur_file_path] = &ScopeTree{
				start_byte: node.start_byte()
				end_byte: node.end_byte()
			}
		}

		return an.store.opened_scopes[an.cur_file_path]
	} else {
		an.store.opened_scopes[an.cur_file_path].children << &ScopeTree{
			start_byte: node.start_byte()
			end_byte: node.end_byte()
			parent: an.store.opened_scopes[an.cur_file_path]
		}

		return an.store.opened_scopes[an.cur_file_path].children.last()
	}
}

fn (mut an Analyzer) next() bool {
	mut rep := 0
	if !an.cursor.next() {
		return false
	}

	for !an.current_node().is_named() && rep < 5 {
		if !an.cursor.next() {
			return false
		}

		rep++
	}

	return true
}

fn (mut an Analyzer) current_node() C.TSNode {
	return an.cursor.current_node()
}

pub fn (mut an Analyzer) infer_value_type(right C.TSNode) &TypeSymbol {
	if right.is_null() {
		return &TypeSymbol(0)
	}

	node_type := right.get_type()
	// TODO
	mut typ := match node_type {
		'true', 'false' { 'bool' }
		'int_literal' { 'int' }
		'float_literal' { 'f32' }
		'rune_literal' { 'byte' }
		'interpreted_string_literal' { 'string' }
		else { '' }
	}

	return an.store.find_symbol(typ)
}

pub fn (mut an Analyzer) top_level_statement() {
	if an.cursor.current_node().is_null() {
		unsafe { an.cursor.free() }
		return
	}

	mut node_type := an.current_node().get_type()
	mut access := SymbolAccess.private
	if node_type == 'source_file' {
		an.cursor.to_first_child()
		node_type = an.current_node().get_type()
	}

	range :=  an.current_node().range()
	mut global_scope := an.get_scope(an.current_node().parent())

	match node_type {
		'import_declaration' {
			an.cursor.to_first_child()
			an.next()

			// spec_node := an.cursor.current_node()
			// println(mod_path.sexpr_str())
			// mod_path := spec_node.child_by_field_name('path').get_text(an.src_text)
			// mod_alias := spec_node.child_by_field_name('alias')

			// print(mod_path)
			// if !mod_alias.is_null() {
			// 	println(' | alias: ${mod_alias.child_by_field_name('name').get_text(an.src_text)}')
			// }

			an.cursor.to_parent()
		}
		'const_declaration' {
			an.cursor.to_first_child()
			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
			}

			an.next()
			for an.current_node().get_type() == 'const_spec' {
				spec_node := an.current_node()
				mut const_sym := &TypeSymbol{	
					name: spec_node.child_by_field_name('name').get_text(an.src_text)
					kind: .variable
					access: access
					range: spec_node.range()
				}

				const_sym.return_type = an.infer_value_type(spec_node.child_by_field_name('value'))
				an.store.register_symbol(const_sym) or { eprint(err) }
				global_scope.register(const_sym)
				if !an.next() {
					break
				}
			}

			an.cursor.to_parent()
		}
		'struct_declaration' {
			an.cursor.to_first_child()
			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
			}
			
			an.next()
			mut sym := &TypeSymbol{
				name: an.current_node().get_text(an.src_text)
				access: access
				range: range
				kind: .struct_
			}
			
			an.next()
			fields_len := an.current_node().named_child_count()
			mut scope := an.get_scope(an.current_node())

			an.cursor.to_first_child()
			for i := 0; i < fields_len; i++ {
				an.next()
				field_node := an.current_node()

				if field_node.get_type() == 'struct_field_scope' {
					scope_text := field_node.get_text(an.src_text)
					access = match scope_text {
						'mut:' { SymbolAccess.private_mutable }
						'pub:' { SymbolAccess.public }
						'pub mut:' { SymbolAccess.public_mutable }
						'__global:' { SymbolAccess.global }
						else { access }
					}
				}

				if field_node.get_type() != 'struct_field_declaration' {
					continue
				} 
				
				field_typ := an.store.find_symbol(field_node.child_by_field_name('type').get_text(an.src_text))
				mut field_sym := &TypeSymbol{
					name: field_node.child_by_field_name('name').get_text(an.src_text)
					kind: .field
					range: field_node.range()
					access: access
					return_type: field_typ
				}

				sym.add_child(mut field_sym) or { 
					eprintln(err)
				}

				scope.register(field_sym)
			}

			an.store.register_symbol(sym) or { eprintln(err) }
			an.cursor.to_parent()
			an.cursor.to_parent()
		}
		'interface_declaration' {
			// TODO: refactor
			an.cursor.to_first_child()
			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
			}
			
			an.next()
			mut sym := &TypeSymbol{
				name: an.current_node().get_text(an.src_text)
				access: access
				range: range
				kind: .struct_
			}

			an.next()

			fields_len := an.current_node().named_child_count()
			an.cursor.to_first_child()
			for i := 0; i < fields_len; i++ {
				an.next()
				field_node := an.current_node()
				match field_node.get_type() {
					'interface_field_scope' {
						// TODO: add if mut: check
						access = .private_mutable
					}
					'interface_spec' {
						param_node := field_node.child_by_field_name('parameters')
						name_node := field_node.child_by_field_name('name')
						result_node := field_node.child_by_field_name('result')

						mut spec_sym := &TypeSymbol{
							name: name_node.get_text(an.src_text)
							kind: .field
							range: field_node.range()
							access: access
							return_type: an.store.find_symbol(result_node.get_text(an.src_text))
						}

						an.store.register_symbol(spec_sym) or { eprintln(err) }

						// scan params
						params_len := param_node.named_child_count()
						an.cursor.reset(param_node)
						an.cursor.to_first_child()

						for j := 0; j < params_len; j++ {
							if !an.current_node().is_named() {
								an.next()
							}

							an.cursor.to_first_child()
							if an.current_node().get_type() == 'mut' {
								access = SymbolAccess.private_mutable
								an.next()
							}

							param_name := an.current_node().get_text(an.src_text)
							param_range := an.current_node().range()
							an.next()

							param_type := an.current_node().get_text(an.src_text)
							mut typ := an.store.find_symbol(param_type)
							mut param_sym := &TypeSymbol{
								name: param_name
								kind: .variable
								range: param_range
								access: access
							}

							if !isnil(typ) {
								param_sym.return_type = typ
							}

							spec_sym.add_child(mut param_sym) or { eprintln(err) }
						}

						an.cursor.to_parent()
						an.cursor.to_parent()	

						sym.add_child(mut spec_sym) or {
							eprintln(err)
						}
					}
					'struct_field_declaration' {
						field_typ := an.store.find_symbol(field_node.child_by_field_name('type').get_text(an.src_text))
						mut field_sym := &TypeSymbol{
							name: field_node.child_by_field_name('name').get_text(an.src_text)
							kind: .field
							range: field_node.range()
							access: access
							return_type: field_typ
						}

						sym.add_child(mut field_sym) or { 
							eprintln(err)
						}
					}
					else { continue }
				}
				// scope.register(field_sym)
			}

			an.store.register_symbol(sym) or { eprintln(err) }
			an.cursor.to_parent()
			an.cursor.to_parent()
		}
		'enum_declaration' {
			an.cursor.to_first_child()

			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
				an.cursor.next()
			}

			an.next()
			mut sym := &TypeSymbol{
				name: an.current_node().get_text(an.src_text)
				access: access
				range: range
				kind: .enum_
			}
			
			an.next()
			members_len := an.current_node().named_child_count()

			an.cursor.to_first_child()
			for i := 0; i < members_len; i++ {
				an.next()
				member_node := an.current_node()
				if member_node.get_type() != 'enum_member' {
					continue
				}

				mut member_sym := &TypeSymbol{
					name: member_node.child_by_field_name('name').get_text(an.src_text)
					kind: .field
					range: member_node.range()
					access: access
					return_type: an.store.find_symbol('int')
				}

				sym.add_child(mut member_sym) or { 
					eprintln(err)
				}
			}

			an.store.register_symbol(sym) or { eprintln(err) }
			an.cursor.to_parent()
			an.cursor.to_parent()
		}
		'function_declaration' {
			fn_node := an.current_node()
			receiver_node := fn_node.child_by_field_name('receiver')
			param_node := fn_node.child_by_field_name('parameters')
			name_node := fn_node.child_by_field_name('name')
			body_node := fn_node.child_by_field_name('body')

			an.cursor.to_first_child()
			if an.current_node().get_type() == 'pub' {
				access = SymbolAccess.public
			}

			mut scope := an.get_scope(body_node)
			mut fn_sym := &TypeSymbol{
				name: name_node.get_text(an.src_text)
				kind: .function
				range: range
				access: access
			}

			if !receiver_node.is_null() {
				an.cursor.reset(receiver_node)
				an.cursor.to_first_child()
				an.cursor.next()
				an.cursor.to_first_child()
				if an.current_node().get_type() == 'mut' {
					access = SymbolAccess.private_mutable
					an.next()
				}

				rec_name := an.current_node().get_text(an.src_text)
				an.next()

				rec_type := an.current_node().get_text(an.src_text)
				mut typ := an.store.find_symbol(rec_type)	
				mut receiver_sym := &TypeSymbol{
					name: rec_name
					kind: .variable
					range: receiver_node.range()
					access: access
				}

				if !isnil(typ) {
					receiver_sym.return_type = typ
					typ.add_child(mut fn_sym) or { eprintln(err) }
				}

				fn_sym.add_child(mut receiver_sym) or { eprintln(err) }
				scope.register(receiver_sym)
				an.cursor.to_parent()

				access = .private
			} else {
				an.store.register_symbol(fn_sym) or { eprintln(err) }
			}

			// scan params
			params_len := param_node.named_child_count()
			an.cursor.reset(param_node)
			an.cursor.to_first_child()

			for i := 0; i < params_len; i++ {
				if !an.current_node().is_named() {
					an.next()
				}

				an.cursor.to_first_child()
				if an.current_node().get_type() == 'mut' {
					access = SymbolAccess.private_mutable
					an.next()
				}

				param_name := an.current_node().get_text(an.src_text)
				param_range := an.current_node().range()
				an.next()

				param_type := an.current_node().get_text(an.src_text)

				mut typ := an.store.find_symbol(param_type)
				mut param_sym := &TypeSymbol{
					name: param_name
					kind: .variable
					range: param_range
					access: access
				}

				if !isnil(typ) {
					param_sym.return_type = typ
				}

				fn_sym.add_child(mut param_sym) or { eprintln(err) }
				scope.register(param_sym)
			}

			an.cursor.to_parent()
			an.cursor.to_parent()

			fn_sym.return_type = an.store.find_symbol(fn_node.child_by_field_name('result').get_text(an.src_text))
			body_sym_len := body_node.named_child_count()

			an.cursor.reset(body_node)
			an.cursor.to_first_child()
			for i := 0; i < body_sym_len; i++ {
				an.next()
				if an.current_node().get_type() != 'short_var_declaration' {
					continue
				}

				decl_node := an.current_node()
				left_expr_lists := decl_node.child_by_field_name('left')
				right_expr_lists := decl_node.child_by_field_name('right')
				left_len := left_expr_lists.named_child_count()
				right_len := right_expr_lists.named_child_count()

				if left_len == right_len {
					for j in 0 .. left_len {
						mut var_access := SymbolAccess.private

						left := left_expr_lists.named_child(j)
						right := right_expr_lists.named_child(j)

						prev_left := left.prev_sibling()
						if !prev_left.is_null() && prev_left.get_type() == 'mut' {
							var_access = .private_mutable
						}

						right_type := an.infer_value_type(right)
						mut var_sym := &TypeSymbol{
							name: left.get_text(an.src_text)
							kind: .variable
							access: var_access
							range: decl_node.range()
							return_type: right_type
						}

						scope.register(var_sym)
					}
				} else {
					// TODO: if left_len > right_len
					// and right_len < left_len
				}

			}
		}
		else {}
	}

	an.next()
}

pub fn (mut an Analyzer) analyze(root_node C.TSNode, src_text []byte, mut store Store) {
	an.store = unsafe { store }
	an.src_text = src_text
	child_len := int(root_node.child_count())
	an.cursor = root_node.tree_cursor()

	for _ in 0 .. child_len {
		an.top_level_statement()
	}

	unsafe { an.cursor.free() }
}