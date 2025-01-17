/**
 *  Port of Morten S. Mikkelsen's original tangent space algorithm
 *  implementation written in C.
 *
 *  Original work: Copyright (C) 2011 by Morten S. Mikkelsen
 *  Modified work: Copyright (C) 2025 by Matthew Taylor
 *
 *  This software is provided 'as-is', without any express or implied
 *  warranty.  In no event will the authors be held liable for any damages
 *  arising from the use of this software.
 *
 *  Permission is granted to anyone to use this software for any purpose,
 *  including commercial applications, and to alter it and redistribute it
 *  freely, subject to the following restrictions:
 *
 *  1. The origin of this software must not be misrepresented; you must not
 *     claim that you wrote the original software. If you use this software
 *     in a product, an acknowledgment in the product documentation would be
 *     appreciated but is not required.
 *  2. Altered source versions must be plainly marked as such, and must not be
 *     misrepresented as being the original software.
 *  3. This notice may not be removed or altered from any source distribution.
 */

MikkInterface :: struct {
	// Returns the number of faces (triangles/quads) on the mesh to be processed.
	get_num_faces: (pContext: *MikkContext) -> int;

	// Returns the number of vertices on face number iFace
	// iFace is a number in the range {0, 1, ..., getNumFaces()-1}
	get_num_vertices_of_face: (pContext: *MikkContext, iFace: int) -> int;

	// returns the position/normal/texcoord of the referenced face of vertex number iVert.
	// iVert is in the range {0,1,2} for triangles and {0,1,2,3} for quads.
	get_position:  (pContext: *MikkContext, iFace: int, iVert: int) -> Vector3;
	get_normal:    (pContext: *MikkContext, iFace: int, iVert: int) -> Vector3;
	get_tex_coord: (pContext: *MikkContext, iFace: int, iVert: int) -> Vector2;

	// either (or both) of the two setTSpace callbacks can be set.
	// The call-back m_setTSpaceBasic() is sufficient for basic normal mapping.

	// This function is used to return the tangent and fSign to the application.
	// fvTangent is a unit length vector.
	// For normal maps it is sufficient to use the following simplified version of the bitangent which is generated at pixel/vertex level.
	// bitangent = fSign * cross(vN, tangent);
	// Note that the results are returned unindexed. It is possible to generate a new index list
	// But averaging/overwriting tangent spaces by using an already existing index list WILL produce INCORRECT results.
	// DO NOT! use an already existing index list.
	set_t_space_basic: (pContext: *MikkContext, fvTangent: Vector3, fSign: float32, iFace: int, iVert: int);

	// This function is used to return tangent space results to the application.
	// fvTangent and fvBiTangent are unit length vectors and fMagS and fMagT are their
	// true magnitudes which can be used for relief mapping effects.
	// fvBiTangent is the "real" bitangent and thus may not be perpendicular to fvTangent.
	// However, both are perpendicular to the vertex normal.
	// For normal maps it is sufficient to use the following simplified version of the bitangent which is generated at pixel/vertex level.
	// fSign = bIsOrientationPreserving ? 1.0f : (-1.0f);
	// bitangent = fSign * cross(vN, tangent);
	// Note that the results are returned unindexed. It is possible to generate a new index list
	// But averaging/overwriting tangent spaces by using an already existing index list WILL produce INCRORRECT results.
	// DO NOT! use an already existing index list.
	set_t_space: (
		pContext: *MikkContext,
		fvTangent: Vector3,
		fvBiTangent: Vector3,
		fMagS: float32,
		fMagT: float32,
		bIsOrientationPreserving: bool,
		iFace: int,
		iVert: int
	);
}

MikkContext :: struct {
	mikk_interface: *MikkInterface; // initialized with callback functions
	user_data: *void; // pointer to client side mesh data etc. (passed as the first parameter with every interface call)
}

// Generates tangents using the provided interface and user data.
// Returns true if the operation succeeded, otherwise false.
generate_tangents :: (pContext: *MikkContext, fAngularThreshold: float32 = 180.0) -> bool {
	// count nr_triangles
	iNrTrianglesIn: int;
	iNrTSPaces, iTotTris, iDegenTriangles, iNrMaxGroups: int;
	iNrActiveGroups, index: int;
	iNrFaces := pContext.mikk_interface.get_num_faces(pContext);
	bRes: bool;
	fThresCos := cos((fAngularThreshold * PI) / 180.0);

	// verify all call-backs have been set
	if pContext.mikk_interface.get_num_faces == null ||
	   pContext.mikk_interface.get_num_vertices_of_face == null ||
	   pContext.mikk_interface.get_position == null ||
	   pContext.mikk_interface.get_normal == null ||
	   pContext.mikk_interface.get_tex_coord == null {
	   return false;
	}

	// count triangles on supported faces
	for f: 0 .. iNrFaces-1 {
		verts := pContext.mikk_interface.get_num_vertices_of_face(pContext, f);
		if verts == 3 then iNrTrianglesIn += 1;
		else if verts == 4 then iNrTrianglesIn += 2;
	}
	if iNrTrianglesIn <= 0 then return false;

	// allocate memory for an index list
	piTriListIn := NewArray(3 * iNrTrianglesIn, int);
	if piTriListIn.data == null then return false;
	defer free(piTriListIn.data);

	pTriInfos := NewArray(iNrTrianglesIn, Tri_Info);
	if pTriInfos.data == null then return false;
	defer free(pTriInfos.data);

	// make an initial triangle . face index list
	iNrTSPaces = generate_initial_vertices_index_list(pTriInfos, piTriListIn, pContext, iNrTrianglesIn);

	// make a welded index list of identical positions and attributes (pos, norm, texc)
	generate_shared_vertices_index_list(piTriListIn, pContext, iNrTrianglesIn);

	// Mark all degenerate triangles
	iTotTris = iNrTrianglesIn;
	iDegenTriangles = 0;
	for t: 0 .. iTotTris-1 {
		i0 := piTriListIn[t * 3 + 0];
		i1 := piTriListIn[t * 3 + 1];
		i2 := piTriListIn[t * 3 + 2];
		p0 := get_position(pContext, i0);
		p1 := get_position(pContext, i1);
		p2 := get_position(pContext, i2);
		if (p0 == p1) || (p0 == p2) || (p1 == p2) { 	// degenerate
			pTriInfos[t].iFlag |= .MarkDegenerate;
			iDegenTriangles += 1;
		}
	}
	iNrTrianglesIn = iTotTris - iDegenTriangles;

	// mark all triangle pairs that belong to a quad with only one
	// good triangle. These need special treatment in DegenEpilogue().
	// Additionally, move all good triangles to the start of
	// pTriInfos[] and piTriListIn[] without changing order and
	// put the degenerate triangles last.
	degen_prologue(pTriInfos, piTriListIn, iNrTrianglesIn, iTotTris);

	// evaluate triangle level attributes and neighbor list
	init_tri_info(pTriInfos, piTriListIn, pContext, iNrTrianglesIn);

	// based on the 4 rules, identify groups based on connectivity
	iNrMaxGroups = iNrTrianglesIn * 3;

	pGroups := NewArray(iNrMaxGroups, Group);
	if pGroups.data == null then return false;
	defer free(pGroups.data);

	piGroupTrianglesBuffer := NewArray(iNrTrianglesIn * 3, int);
	if piGroupTrianglesBuffer.data == null then return false;
	defer free(piGroupTrianglesBuffer.data);

	iNrActiveGroups = build_4_rule_groups(pTriInfos, pGroups, piGroupTrianglesBuffer, piTriListIn, iNrTrianglesIn);

	psTspace := NewArray(iNrTSPaces, T_Space);
	if psTspace.data == null then return false;
	defer free(psTspace.data);

	for t: 0 .. iNrTSPaces-1 {
		psTspace[t].vOs.x = 1.0;
		psTspace[t].vOs.y = 0.0;
		psTspace[t].vOs.z = 0.0;
		psTspace[t].fMagS = 1.0;
		psTspace[t].vOt.x = 0.0;
		psTspace[t].vOt.y = 1.0;
		psTspace[t].vOt.z = 0.0;
		psTspace[t].fMagT = 1.0;
	}

	// make tspaces, each group is split up into subgroups if necessary
	// based on fAngularThreshold. Finally a tangent space is made for
	// every resulting subgroup
	bRes = generate_t_spaces(psTspace, pTriInfos, pGroups, iNrActiveGroups, piTriListIn, fThresCos, pContext);

	// clean up

	if !bRes {
		return false;
	}


	// degenerate quads with one good triangle will be fixed by copying a space from
	// the good triangle to the coinciding vertex.
	// all other degenerate triangles will just copy a space from any good triangle
	// with the same welded index in piTriListIn[].
	degen_epilogue(psTspace, pTriInfos, piTriListIn, pContext, iNrTrianglesIn, iTotTris);

	index = 0;
	for f: 0 .. iNrFaces-1 {
		verts := pContext.mikk_interface.get_num_vertices_of_face(pContext, f);
		if verts != 3 && verts != 4 then continue;

		for i: 0 .. verts-1 {
			pTSpace := *psTspace[index];
			tang := Vector3.{pTSpace.vOs.x, pTSpace.vOs.y, pTSpace.vOs.z};
			bitang := Vector3.{pTSpace.vOt.x, pTSpace.vOt.y, pTSpace.vOt.z};

			if pContext.mikk_interface.set_t_space != null {
				pContext.mikk_interface.set_t_space(pContext, tang, bitang, pTSpace.fMagS, pTSpace.fMagT, pTSpace.bOrient, f, i);
			}

			if pContext.mikk_interface.set_t_space_basic != null {
				pContext.mikk_interface.set_t_space_basic(pContext, tang, ifx pTSpace.bOrient == true then 1.0 else -1.0, f, i);
			}

			index += 1;
		}
	}

	return true;
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////

#scope_module

INTERNAL_RND_SORT_SEED: u32 : 39871946;

Sub_Group :: struct {
	iNrFaces:    int;
	pTriMembers: [] int;
}

Group :: struct {
	iNrFaces:              int;
	pFaceIndices:          [] int;
	iVertexRepresentitive: int;
	bOrientPreservering:   bool;
}

Tri_Flags :: enum_flags {
	MarkDegenerate;
	QuadOneDegenTri;
	GroupWithAny;
	OrientPreserving;
}

Tri_Info :: struct {
	FaceNeighbors:  [3]int;
	AssignedGroup:  [3]*Group;

	// normalized first order face derivatives
	vOs, vOt:       Vector3;
	fMagS, fMagT:   float32;

	// determines if the current and the next triangle are a quad.
	iOrgFaceNumber: int;
	iFlag:          Tri_Flags;
	iTSpacesOffs:   int;
	vert_num:       [4]u8;
}

T_Space :: struct {
	vOs:      Vector3;
	fMagS:    float32;
	vOt:      Vector3;
	fMagT:    float32;
	iCounter: int; // this is to average back into quads.
	bOrient:  bool;
}

make_index :: (iFace: int, iVert: int) -> int {
	assert(iVert >= 0 && iVert < 4 && iFace >= 0);
	return (iFace << 2) | (iVert & 0x3);
}

index_to_data :: (piFace: *int, piVert: *int, iIndexIn: int) {
	piVert.* = iIndexIn & 0x3;
	piFace.* = iIndexIn >> 2;
}

avg_t_space :: (pTS0: *T_Space, pTS1: *T_Space) -> T_Space {
	ts_res: T_Space;

	// this if is important. Due to floating point precision
	// averaging when ts0==ts1 will cause a slight difference
	// which results in tangent space splits later on
	if pTS0.fMagS == pTS1.fMagS && pTS0.fMagT == pTS1.fMagT && pTS0.vOs == pTS1.vOs && pTS0.vOt == pTS1.vOt {
		ts_res.fMagS = pTS0.fMagS;
		ts_res.fMagT = pTS0.fMagT;
		ts_res.vOs = pTS0.vOs;
		ts_res.vOt = pTS0.vOt;
	} else {
		ts_res.fMagS = 0.5 * (pTS0.fMagS + pTS1.fMagS);
		ts_res.fMagT = 0.5 * (pTS0.fMagT + pTS1.fMagT);
		ts_res.vOs = pTS0.vOs + pTS1.vOs;
		ts_res.vOt = pTS0.vOt + pTS1.vOt;
		ts_res.vOs = normalize(ts_res.vOs);
		ts_res.vOt = normalize(ts_res.vOt);
	}

	return ts_res;
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////

Tmp_Vert :: struct {
	vert:  Vector3;
	index: int;
}

G_CELLS :: 2048;

// it is IMPORTANT that this function is called to evaluate the hash since
// inlining could potentially reorder instructions and generate different
// results for the same effective input value fVal.
// FindGridCell
find_grid_cell :: no_inline (fMin: float32, fMax: float32, fVal: float32) -> int {
	fIndex := cast(float32, G_CELLS) * ((fVal - fMin) / (fMax - fMin));
	iIndex := cast(int, fIndex);
	return ifx iIndex < G_CELLS then (ifx iIndex >= 0 then iIndex else 0) else (G_CELLS - 1);
}

generate_shared_vertices_index_list :: (piTriList_in_and_out: []int, pContext: *MikkContext, iNrTrianglesIn: int) {
	// Generate bounding box
	iChannel: int;
	iMaxCount: int;
	vMin := get_position(pContext, 0);
	vMax := vMin;
	vDim: Vector3;
	fMin, fMax: float32;
	for i: 1 .. (iNrTrianglesIn * 3)-1 {
		index := piTriList_in_and_out[i];

		vP := get_position(pContext, index);

		if vMin.x > vP.x      then vMin.x = vP.x;
		else if vMax.x < vP.x then vMax.x = vP.x;
		if vMin.y > vP.y      then vMin.y = vP.y;
		else if vMax.y < vP.y then vMax.y = vP.y;
		if vMin.z > vP.z      then vMin.z = vP.z;
		else if vMax.z < vP.z then vMax.z = vP.z;
	}

	vDim = vMax - vMin;
	iChannel = 0;
	fMin = vMin.x;
	fMax = vMax.x;
	if vDim.y > vDim.x && vDim.y > vDim.z {
		iChannel = 1;
		fMin = vMin.y;
		fMax = vMax.y;
	} else if vDim.z > vDim.x {
		iChannel = 2;
		fMin = vMin.z;
		fMax = vMax.z;
	}

	// make allocations
	piHashTable := NewArray(iNrTrianglesIn * 3, int);
	defer if piHashTable.data then free(piHashTable.data);

	piHashCount := NewArray(G_CELLS, int);
	defer if piHashCount.data then free(piHashCount.data);

	piHashOffsets := NewArray(G_CELLS, int);
	defer if piHashOffsets.data then free(piHashOffsets.data);

	piHashCount2 := NewArray(G_CELLS, int);
	defer if piHashCount2.data then free(piHashCount2.data);

	if piHashTable.data   == null || 
	   piHashCount.data   == null || 
	   piHashOffsets.data == null ||
	   piHashCount2.data  == null 
    {
		generate_shared_vertices_index_list_slow(piTriList_in_and_out, pContext, iNrTrianglesIn);
		return;
	}

	// count amount of elements in each cell unit
	for i: 0 .. (iNrTrianglesIn * 3)-1 {
		index := piTriList_in_and_out[i];
		vP := get_position(pContext, index);
		fVal := ifx iChannel == 0 then vP.x else (ifx iChannel == 1 then vP.y else vP.z);
		iCell := find_grid_cell(fMin, fMax, fVal);
		piHashCount[iCell] += 1;
	}

	// evaluate start index of each cell.
	piHashOffsets[0] = 0;
	for k: 1 .. G_CELLS-1 {
		piHashOffsets[k] = piHashOffsets[k - 1] + piHashCount[k - 1];
	}

	// insert vertices
	for i: 0 .. (iNrTrianglesIn * 3)-1 {
		index := piTriList_in_and_out[i];
		vP := get_position(pContext, index);
		fVal := ifx iChannel == 0 then vP.x else (ifx iChannel == 1 then vP.y else vP.z);
		iCell := find_grid_cell(fMin, fMax, fVal);

		assert(piHashCount2[iCell] < piHashCount[iCell]);
		pTable := array_view(piHashTable, piHashOffsets[iCell]);
		pTable[piHashCount2[iCell]] = i; // vertex i has been inserted.
		piHashCount2[iCell] += 1;
	}

	for k: 0 .. G_CELLS-1 {
		assert(piHashCount2[k] == piHashCount[k]); // verify the count
	}

	// find maximum amount of entries in any hash entry
	iMaxCount = piHashCount[0];

	for k: 1 .. G_CELLS-1 {
		if iMaxCount < piHashCount[k] {
			iMaxCount = piHashCount[k];
		}
	}

	pTmpVert := NewArray(iMaxCount, Tmp_Vert);
	defer { if pTmpVert.data != null then free(pTmpVert.data); }

	// complete the merge
	for k: 0 .. G_CELLS-1 {
		// extract table of cell k and amount of entries in it
		pTable := array_view(piHashTable, piHashOffsets[k]);
		iEntries := piHashCount[k];
		if iEntries < 2 then continue;

		if pTmpVert.data != null {
			for e: 0 .. iEntries-1 {
				i := pTable[e];
				vP := get_position(pContext, piTriList_in_and_out[i]);
				pTmpVert[e].vert.component[0] = vP.x;
				pTmpVert[e].vert.component[1] = vP.y;
				pTmpVert[e].vert.component[2] = vP.z;
				pTmpVert[e].index = i;
			}
			merge_verts_fast(piTriList_in_and_out, pTmpVert, pContext, 0, iEntries - 1);
		} else {
			merge_verts_slow(piTriList_in_and_out, pContext, pTable, iEntries);
		}
	}
}

merge_verts_fast :: (piTriList_in_and_out: []int, pTmpVert: []Tmp_Vert, pContext: *MikkContext, iL_in: int, iR_in: int) {
	// make bbox
	fvMin, fvMax: Vector3;
	dx, dy, dz, fSep: float32;
	for c: 0 .. 2 {
		fvMin.component[c] = pTmpVert[iL_in].vert.component[c];
		fvMax.component[c] = fvMin.component[c];
	}
	for l: (iL_in + 1) .. iR_in {
		for c: 0 .. 2 {
			if fvMin.component[c] > pTmpVert[l].vert.component[c] then fvMin.component[c] = pTmpVert[l].vert.component[c];
			if fvMax.component[c] < pTmpVert[l].vert.component[c] then fvMax.component[c] = pTmpVert[l].vert.component[c];
		}
	}

	dx = fvMax.component[0] - fvMin.component[0];
	dy = fvMax.component[1] - fvMin.component[1];
	dz = fvMax.component[2] - fvMin.component[2];

	channel := 0;
	if dy > dx && dy > dz then channel = 1;
	else if dz > dx       then channel = 2;

	fSep = 0.5 * (fvMax.component[channel] + fvMin.component[channel]);

	// stop if all vertices are NaNs
	if isnan(fSep) || isinf(fSep) then return;

	// terminate recursion when the separation/average value
	// is no longer strictly between fMin and fMax values.
	if fSep >= fvMax.component[channel] || fSep <= fvMin.component[channel] {
		// complete the weld
		for l: 0 .. iR_in {
			i := pTmpVert[l].index;
			index := piTriList_in_and_out[i];
			vP := get_position(pContext, index);
			vN := get_normal(pContext, index);
			vT := get_tex_coord(pContext, index);

			bNotFound := true;
			l2 := iL_in;
			i2rec := -1;
			while l2 < l && bNotFound {
				i2 := pTmpVert[l2].index;
				index2 := piTriList_in_and_out[i2];
				vP2 := get_position(pContext, index2);
				vN2 := get_normal(pContext, index2);
				vT2 := get_tex_coord(pContext, index2);
				i2rec = i2;

				if vP == vP2 && vN == vN2 && vT == vT2 {
					bNotFound = false;
				} else {
					l2 += 1;
				}
			}

			// merge if previously found
			if !bNotFound {
				piTriList_in_and_out[i] = piTriList_in_and_out[i2rec];
			}
		}
	} else {
		iL := iL_in;
		iR := iR_in;
		assert((iR_in - iL_in) > 0); // at least 2 entries

		// separate (by fSep) all points between iL_in and iR_in in pTmpVert[]
		while iL < iR {
			bReadyLeftSwap := false;
			bReadyRightSwap := false;
			while (!bReadyLeftSwap) && iL < iR {
				assert(iL >= iL_in && iL <= iR_in);
				bReadyLeftSwap = !(pTmpVert[iL].vert.component[channel] < fSep);
				if !bReadyLeftSwap then iL += 1;
			}
			while (!bReadyRightSwap) && iL < iR {
				assert(iR >= iL_in && iR <= iR_in);
				bReadyRightSwap = pTmpVert[iR].vert.component[channel] < fSep;
				if !bReadyRightSwap then iR -= 1;
			}
			assert((iL < iR) || !(bReadyLeftSwap && bReadyRightSwap));

			if bReadyLeftSwap && bReadyRightSwap {
				sTmp: Tmp_Vert = pTmpVert[iL];
				assert(iL < iR);
				pTmpVert[iL] = pTmpVert[iR];
				pTmpVert[iR] = sTmp;
				iL += 1;
				iR -= 1;
			}
		}

		assert(iL == (iR + 1) || (iL == iR));
		if iL == iR {
			bReadyRightSwap := pTmpVert[iR].vert.component[channel] < fSep;
			if bReadyRightSwap {
				iL += 1;
			} else {
				iR -= 1;
			}
		}

		// only need to weld when there is more than 1 instance of the (x,y,z)
		if iL_in < iR {
			merge_verts_fast(piTriList_in_and_out, pTmpVert, pContext, iL_in, iR); // weld all left of fSep
		}
		if iL < iR_in {
			merge_verts_fast(piTriList_in_and_out, pTmpVert, pContext, iL, iR_in); // weld all right of (or equal to) fSep
		}
	}
}

merge_verts_slow :: (piTriList_in_and_out: []int, pContext: *MikkContext, pTable: []int, iEntries: int) {
	// this can be optimized further using a tree structure or more hashing.
	for e: 0 .. iEntries-1 {
		i := pTable[e];
		index := piTriList_in_and_out[i];
		vP := get_position(pContext, index);
		vN := get_normal(pContext, index);
		vT := get_tex_coord(pContext, index);

		bNotFound := true;
		e2 := 0;
		i2rec := -1;

		while e2 < e && bNotFound {
			i2 := pTable[e2];
			index2 := piTriList_in_and_out[i2];
			vP2 := get_position(pContext, index2);
			vN2 := get_normal(pContext, index2);
			vT2 := get_tex_coord(pContext, index2);
			i2rec = i2;

			if (vP == vP2) && (vN == vN2) && (vT == vT2) {
				bNotFound = false;
			} else {
				e2 += 1;
			}
		}

		// merge if previously found
		if !bNotFound {
			piTriList_in_and_out[i] = piTriList_in_and_out[i2rec];
		}
	}
}

generate_shared_vertices_index_list_slow :: (piTriList_in_and_out: []int, pContext: *MikkContext, iNrTrianglesIn: int) {
	iNumUniqueVerts := 0;
	for t: 0 .. iNrTrianglesIn-1 {
		for i: 0 .. 2 {
			offs := t * 3 + i;
			index := piTriList_in_and_out[offs];

			vP: Vector3 = get_position(pContext, index);
			vN: Vector3 = get_normal(pContext, index);
			vT: Vector3 = get_tex_coord(pContext, index);

			bFound := false;
			t2 := 0;
			index2rec := -1;
			while !bFound && t2 <= t {
				j := 0;
				while !bFound && j < 3 {
					index2 := piTriList_in_and_out[t2 * 3 + j];
					vP2 := get_position(pContext, index2);
					vN2 := get_normal(pContext, index2);
					vT2 := get_tex_coord(pContext, index2);

					if (vP == vP2) && (vN == vN2) && (vT == vT2) {
						bFound = true;
					} else {
						j += 1;
					}
				}

				if !bFound then t2 += 1;
			}

			assert(bFound);
			// if we found our own
			if index2rec == index then iNumUniqueVerts += 1;

			piTriList_in_and_out[offs] = index2rec;
		}
	}
}

generate_initial_vertices_index_list :: (pTriInfos: []Tri_Info, piTriList_out: []int, pContext: *MikkContext, iNrTrianglesIn: int) -> int {
	iTSpacesOffs := 0;
	iDstTriIndex := 0;

	for f: 0 .. pContext.mikk_interface.get_num_faces(pContext)-1 {
		verts := pContext.mikk_interface.get_num_vertices_of_face(pContext, f);
		if verts != 3 && verts != 4 then continue;

		pTriInfos[iDstTriIndex].iOrgFaceNumber = f;
		pTriInfos[iDstTriIndex].iTSpacesOffs = iTSpacesOffs;

		if verts == 3 {
			pVerts: [] u8 = pTriInfos[iDstTriIndex].vert_num;
			pVerts[0] = 0;
			pVerts[1] = 1;
			pVerts[2] = 2;
			piTriList_out[iDstTriIndex * 3 + 0] = make_index(f, 0);
			piTriList_out[iDstTriIndex * 3 + 1] = make_index(f, 1);
			piTriList_out[iDstTriIndex * 3 + 2] = make_index(f, 2);
			iDstTriIndex += 1; // next
		} else {
			{
				pTriInfos[iDstTriIndex + 1].iOrgFaceNumber = f;
				pTriInfos[iDstTriIndex + 1].iTSpacesOffs = iTSpacesOffs;
			}

			{
				// need an order independent way to evaluate
				// tspace on quads. This is done by splitting
				// along the shortest diagonal.
				i0 := make_index(f, 0);
				i1 := make_index(f, 1);
				i2 := make_index(f, 2);
				i3 := make_index(f, 3);
				T0 := get_tex_coord(pContext, i0);
				T1 := get_tex_coord(pContext, i1);
				T2 := get_tex_coord(pContext, i2);
				T3 := get_tex_coord(pContext, i3);
				distSQ_02 := length_squared(T2 - T0);
				distSQ_13 := length_squared(T3 - T1);
				bQuadDiagIs_02: bool;
				if distSQ_02 < distSQ_13 {
					bQuadDiagIs_02 = true;
				} else if distSQ_13 < distSQ_02 {
					bQuadDiagIs_02 = false;
				} else {
					P0 := get_position(pContext, i0);
					P1 := get_position(pContext, i1);
					P2 := get_position(pContext, i2);
					P3 := get_position(pContext, i3);
					distSQ_02 = length_squared(P2 - P0);
					distSQ_13 = length_squared(P3 - P1);

					bQuadDiagIs_02 = ifx distSQ_13 < distSQ_02 then false else true;
				}

				if bQuadDiagIs_02 {
					{
						pVerts_A: [] u8 = pTriInfos[iDstTriIndex].vert_num;
						pVerts_A[0] = 0;
						pVerts_A[1] = 1;
						pVerts_A[2] = 2;
					}
					piTriList_out[iDstTriIndex * 3 + 0] = i0;
					piTriList_out[iDstTriIndex * 3 + 1] = i1;
					piTriList_out[iDstTriIndex * 3 + 2] = i2;
					iDstTriIndex += 1; // next
					{
						pVerts_B: [] u8 = pTriInfos[iDstTriIndex].vert_num;
						pVerts_B[0] = 0;
						pVerts_B[1] = 2;
						pVerts_B[2] = 3;
					}
					piTriList_out[iDstTriIndex * 3 + 0] = i0;
					piTriList_out[iDstTriIndex * 3 + 1] = i2;
					piTriList_out[iDstTriIndex * 3 + 2] = i3;
					iDstTriIndex += 1; // next
				} else {
					{
						pVerts_A: [] u8 = pTriInfos[iDstTriIndex].vert_num;
						pVerts_A[0] = 0;
						pVerts_A[1] = 1;
						pVerts_A[2] = 3;
					}
					piTriList_out[iDstTriIndex * 3 + 0] = i0;
					piTriList_out[iDstTriIndex * 3 + 1] = i1;
					piTriList_out[iDstTriIndex * 3 + 2] = i3;
					iDstTriIndex += 1; // next
					{
						pVerts_B: [] u8 = pTriInfos[iDstTriIndex].vert_num;
						pVerts_B[0] = 1;
						pVerts_B[1] = 2;
						pVerts_B[2] = 3;
					}
					piTriList_out[iDstTriIndex * 3 + 0] = i1;
					piTriList_out[iDstTriIndex * 3 + 1] = i2;
					piTriList_out[iDstTriIndex * 3 + 2] = i3;
					iDstTriIndex += 1; // next
				}
			}
		}

		iTSpacesOffs += verts;
		assert(iDstTriIndex <= iNrTrianglesIn);
	}

	for t: 0 .. iNrTrianglesIn-1 {
		pTriInfos[t].iFlag = 0;
	}

	// return total amount of tspaces
	return iTSpacesOffs;
}

get_position :: (pContext: *MikkContext, index: int) -> Vector3 {
	iF, iI: int;
	index_to_data(*iF, *iI, index);
	pos := pContext.mikk_interface.get_position(pContext, iF, iI);
	return pos;
}

get_normal :: (pContext: *MikkContext, index: int) -> Vector3 {
	iF, iI: int;
	index_to_data(*iF, *iI, index);
	norm := pContext.mikk_interface.get_normal(pContext, iF, iI);
	return norm;
}

get_tex_coord :: (pContext: *MikkContext, index: int) -> Vector3 {
	iF, iI: int;
	res: Vector3;
	index_to_data(*iF, *iI, index);
	texc := pContext.mikk_interface.get_tex_coord(pContext, iF, iI);
	res.xy = texc;
	res.z = 1.0;
	return res;
}

/////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////

Edge :: struct {
	i0, i1, f: int;
	#place i0; array:   [3]int;
}

// returns the texture area times 2
calc_tex_area :: (pContext: *MikkContext, indices: []int) -> float32 {
	t1 := get_tex_coord(pContext, indices[0]);
	t2 := get_tex_coord(pContext, indices[1]);
	t3 := get_tex_coord(pContext, indices[2]);

	t21x := t2.x - t1.x;
	t21y := t2.y - t1.y;
	t31x := t3.x - t1.x;
	t31y := t3.y - t1.y;

	fSignedAreaSTx2 := t21x * t31y - t21y * t31x;

	return ifx fSignedAreaSTx2 < 0 then (-fSignedAreaSTx2) else fSignedAreaSTx2;
}

init_tri_info :: (pTriInfos: []Tri_Info, piTriListIn: []int, pContext: *MikkContext, iNrTrianglesIn: int) {
	// pTriInfos[f].iFlag is cleared in GenerateInitialVerticesIndexList() which is called before this function.

	// generate neighbor info list
	for f: 0 .. iNrTrianglesIn-1 {
		for i: 0 .. 2 {
			pTriInfos[f].FaceNeighbors[i] = -1;
			pTriInfos[f].AssignedGroup[i] = null;

			pTriInfos[f].vOs.x = 0.0;
			pTriInfos[f].vOs.y = 0.0;
			pTriInfos[f].vOs.z = 0.0;
			pTriInfos[f].vOt.x = 0.0;
			pTriInfos[f].vOt.y = 0.0;
			pTriInfos[f].vOt.z = 0.0;
			pTriInfos[f].fMagS = 0;
			pTriInfos[f].fMagT = 0;

			// assumed bad
			pTriInfos[f].iFlag |= .GroupWithAny;
		}
	}

	// evaluate first order derivatives
	for f: 0 .. iNrTrianglesIn-1 {
		// initial values
		v1 := get_position(pContext, piTriListIn[f * 3 + 0]);
		v2 := get_position(pContext, piTriListIn[f * 3 + 1]);
		v3 := get_position(pContext, piTriListIn[f * 3 + 2]);
		t1 := get_tex_coord(pContext, piTriListIn[f * 3 + 0]);
		t2 := get_tex_coord(pContext, piTriListIn[f * 3 + 1]);
		t3 := get_tex_coord(pContext, piTriListIn[f * 3 + 2]);

		t21x := t2.x - t1.x;
		t21y := t2.y - t1.y;
		t31x := t3.x - t1.x;
		t31y := t3.y - t1.y;
		d1 := v2 - v1;
		d2 := v3 - v1;

		fSignedAreaSTx2 := t21x * t31y - t21y * t31x;

		vOs := (t31y * d1) - (t21y * d2);
		vOt := (-t31x * d1) - (t21x * d2);

		if fSignedAreaSTx2 > 0.0 {
			pTriInfos[f].iFlag |= .OrientPreserving;
		}

		if fSignedAreaSTx2 != 0 {
			fAbsArea := abs(fSignedAreaSTx2);
			fLenOs := length(vOs);
			fLenOt := length(vOt);
			fS: float32 = ifx pTriInfos[f].iFlag & .OrientPreserving then -1.0 else 1.0;
			if fLenOs != 0.0 then pTriInfos[f].vOs = (fS / fLenOs) * vOs;
			if fLenOt != 0.0 then pTriInfos[f].vOt = (fS / fLenOt) * vOt;

			// evaluate magnitudes prior to normalization of vOs and vOt
			pTriInfos[f].fMagS = fLenOs / fAbsArea;
			pTriInfos[f].fMagT = fLenOt / fAbsArea;

			// if this is a good triangle
			if pTriInfos[f].fMagS != 0.0 && pTriInfos[f].fMagT != 0.0 {
				pTriInfos[f].iFlag &= ~.GroupWithAny;
			}
		}
	}

	t: int;

	// force otherwise healthy quads to a fixed orientation
	while t < (iNrTrianglesIn - 1) {
		iFO_a := pTriInfos[t].iOrgFaceNumber;
		iFO_b := pTriInfos[t + 1].iOrgFaceNumber;
		if iFO_a == iFO_b { 	// this is a quad
			bIsDeg_a := pTriInfos[t].iFlag & .MarkDegenerate;
			bIsDeg_b := pTriInfos[t + 1].iFlag & .MarkDegenerate;

			// bad triangles should already have been removed by
			// DegenPrologue(), but just in case check bIsDeg_a and bIsDeg_a are false
			if bIsDeg_a || bIsDeg_b {
				bOrientA := !!(pTriInfos[t].iFlag & .OrientPreserving);
				bOrientB := !!(pTriInfos[t + 1].iFlag & .OrientPreserving);
				// if this happens the quad has extremely bad mapping!!
				if bOrientA != bOrientB {
					bChooseOrientFirstTri := false;
					if pTriInfos[t + 1].iFlag & .GroupWithAny {
						bChooseOrientFirstTri = true;
					} else if calc_tex_area(pContext, array_view(piTriListIn, t * 3 + 0)) >= calc_tex_area(pContext, array_view(piTriListIn, (t + 1) * 3 + 0)) {
						bChooseOrientFirstTri = true;
					}

					// force match
					{
						t0 := ifx bChooseOrientFirstTri then t else (t + 1);
						t1 := ifx bChooseOrientFirstTri then (t + 1) else t;
						pTriInfos[t1].iFlag &= ~.OrientPreserving; // clear first
						pTriInfos[t1].iFlag |= pTriInfos[t0].iFlag & .OrientPreserving; // copy bit
					}
				}
			}
			t += 2;
		} else {
			t += 1;
		}
	}

	// match up edge pairs
	{
		pEdges := NewArray(iNrTrianglesIn * 3, Edge);
		defer { if pEdges.data != null then free(pEdges.data); }

		if pEdges.data == null {
			build_neighbors_slow(pTriInfos, piTriListIn, iNrTrianglesIn);
		} else {
			build_neighbors_fast(pTriInfos, pEdges, piTriListIn, iNrTrianglesIn);
		}
	}
}

/////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////

build_4_rule_groups :: (
	pTriInfos: []Tri_Info,
	pGroups: []Group,
	piGroupTrianglesBuffer: []int,
	piTriListIn: []int,
	iNrTrianglesIn: int
) -> int {
	iNrMaxGroups := iNrTrianglesIn * 3;
	iNrActiveGroups: int;
	iOffset: int;

	for f: 0 .. iNrTrianglesIn-1 {
		for i: 0 .. 2 {
			// if not assigned to a group
			if !(pTriInfos[f].iFlag & .GroupWithAny) && pTriInfos[f].AssignedGroup[i] == null {
				bOrPre: bool;
				neigh_indexL, neigh_indexR: int;
				vert_index := piTriListIn[f * 3 + i];
				assert(iNrActiveGroups < iNrMaxGroups);
				pTriInfos[f].AssignedGroup[i] = *pGroups[iNrActiveGroups];
				pTriInfos[f].AssignedGroup[i].iVertexRepresentitive = vert_index;
				pTriInfos[f].AssignedGroup[i].bOrientPreservering = !!(pTriInfos[f].iFlag & .OrientPreserving);
				pTriInfos[f].AssignedGroup[i].iNrFaces = 0;
				pTriInfos[f].AssignedGroup[i].pFaceIndices = array_view(piGroupTrianglesBuffer, iOffset);
				iNrActiveGroups += 1;

				add_tri_to_group(pTriInfos[f].AssignedGroup[i], f);
				bOrPre = !!(pTriInfos[f].iFlag & .OrientPreserving);
				neigh_indexL = pTriInfos[f].FaceNeighbors[i];
				neigh_indexR = pTriInfos[f].FaceNeighbors[ifx i > 0 then (i - 1) else 2];
				if neigh_indexL >= 0 { 	// neighbor
					bAnswer := assign_recur(piTriListIn, pTriInfos, neigh_indexL, pTriInfos[f].AssignedGroup[i]);

					bOrPre2 := !!(pTriInfos[neigh_indexL].iFlag & .OrientPreserving);
					bDiff := bOrPre != bOrPre2;
					assert(bAnswer || bDiff);
				}
				if neigh_indexR >= 0 { 	// neighbor
					bAnswer := assign_recur(piTriListIn, pTriInfos, neigh_indexR, pTriInfos[f].AssignedGroup[i]);

					bOrPre2 := !!(pTriInfos[neigh_indexR].iFlag & .OrientPreserving);
					bDiff := bOrPre != bOrPre2;
					assert(bAnswer || bDiff);
				}

				// update offset
				iOffset += pTriInfos[f].AssignedGroup[i].iNrFaces;
				// since the groups are disjoint a triangle can never
				// belong to more than 3 groups. Subsequently something
				// is completely screwed if this assertion ever hits.
				assert(iOffset <= iNrMaxGroups);
			}
		}
	}

	return iNrActiveGroups;
}

add_tri_to_group :: (pGroup: *Group, iTriIndex: int) {
	pGroup.pFaceIndices[pGroup.iNrFaces] = iTriIndex;
	pGroup.iNrFaces += 1;
}

assign_recur :: (piTriListIn: []int, psTriInfos: []Tri_Info, iMyTriIndex: int, pGroup: *Group) -> bool {
	pMyTriInfo := *psTriInfos[iMyTriIndex];

	// track down vertex
	iVertRep := pGroup.iVertexRepresentitive;
	pVerts := array_view(piTriListIn, 3 * iMyTriIndex + 0);
	i := -1;
	if pVerts[0] == iVertRep then i = 0;
	else if pVerts[1] == iVertRep then i = 1;
	else if pVerts[2] == iVertRep then i = 2;
	assert(i >= 0 && i < 3);

	// early out
	if pMyTriInfo.AssignedGroup[i] == pGroup then return true;
	else if pMyTriInfo.AssignedGroup[i] != null then return false;

	if pMyTriInfo.iFlag & .GroupWithAny {
		// first to group with a group-with-anything triangle
		// determines it's orientation.
		// This is the only existing order dependency in the code!!
		if pMyTriInfo.AssignedGroup[0] == null && pMyTriInfo.AssignedGroup[1] == null && pMyTriInfo.AssignedGroup[2] == null {
			pMyTriInfo.iFlag &= ~.OrientPreserving;
			pMyTriInfo.iFlag |= (ifx pGroup.bOrientPreservering then .OrientPreserving else xx 0);
		}
	}

	{
		bOrient := !!(pMyTriInfo.iFlag & .OrientPreserving);
		if bOrient != pGroup.bOrientPreservering then return false;
	}

	add_tri_to_group(pGroup, iMyTriIndex);
	pMyTriInfo.AssignedGroup[i] = pGroup;

	{
		neigh_indexL := pMyTriInfo.FaceNeighbors[i];
		neigh_indexR := pMyTriInfo.FaceNeighbors[ifx i > 0 then (i - 1) else 2];
		if neigh_indexL >= 0 {
			assign_recur(piTriListIn, psTriInfos, neigh_indexL, pGroup);
		}
		if neigh_indexR >= 0 {
			assign_recur(piTriListIn, psTriInfos, neigh_indexR, pGroup);
		}
	}

	return true;
}

/////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////

generate_t_spaces :: (
	psTspace: []T_Space,
	pTriInfos: []Tri_Info,
	pGroups: []Group,
	iNrActiveGroups: int,
	piTriListIn: []int,
	fThresCos: float32,
	pContext: *MikkContext
) -> bool {
	iMaxNrFaces, iUniqueTspaces: int;
	for g: 0 .. iNrActiveGroups-1 {
		if iMaxNrFaces < pGroups[g].iNrFaces {
			iMaxNrFaces = pGroups[g].iNrFaces;
		}
	}

	if iMaxNrFaces == 0 then return true;

	// make initial allocations
	pSubGroupTspace := NewArray(iMaxNrFaces, T_Space);
	if pSubGroupTspace.data == null then return false;
	defer free(pSubGroupTspace.data);

	pUniSubGroups := NewArray(iMaxNrFaces, Sub_Group);
	if pUniSubGroups.data == null then return false;
	defer free(pUniSubGroups.data);

	pTmpMembers := NewArray(iMaxNrFaces, int);
	if pTmpMembers.data == null then return false;
	defer free(pTmpMembers.data);

	iUniqueTspaces = 0;
	for g: 0 .. iNrActiveGroups-1 {
		pGroup := *pGroups[g];
		iUniqueSubGroups: int;

		for i: 0 .. pGroup.iNrFaces-1 {
			f := pGroup.pFaceIndices[i]; // triangle number
			index := -1;
			iVertIndex := -1;
			iOF_1 := -1;

			iMembers, l: int;
			tmp_group: Sub_Group;
			bFound: bool;
			n, vOs, vOt: Vector3;
			if pTriInfos[f].AssignedGroup[0] == pGroup      then index = 0;
			else if pTriInfos[f].AssignedGroup[1] == pGroup then index = 1;
			else if pTriInfos[f].AssignedGroup[2] == pGroup then index = 2;
			assert(index >= 0 && index < 3);

			iVertIndex = piTriListIn[f * 3 + index];
			assert(iVertIndex == pGroup.iVertexRepresentitive);

			// is normalized already
			n = get_normal(pContext, iVertIndex);

			// project
			vOs = (pTriInfos[f].vOs - (dot(n, pTriInfos[f].vOs) * n));
			vOt = (pTriInfos[f].vOt - (dot(n, pTriInfos[f].vOt) * n));
			vOs = normalize(vOs);
			vOt = normalize(vOt);

			// original face number
			iOF_1 = pTriInfos[f].iOrgFaceNumber;

			iMembers = 0;
			for j: 0 .. pGroup.iNrFaces-1 {
				t := pGroup.pFaceIndices[j]; // triangle number
				iOF_2 := pTriInfos[t].iOrgFaceNumber;

				// project
				vOs2 := pTriInfos[t].vOs - (dot(n, pTriInfos[t].vOs) * n);
				vOt2 := pTriInfos[t].vOt - (dot(n, pTriInfos[t].vOt) * n);
				vOs2 = normalize(vOs2);
				vOt2 = normalize(vOt2);

				{
					bAny := (pTriInfos[f].iFlag | pTriInfos[t].iFlag) & .GroupWithAny;
					// make sure triangles which belong to the same quad are joined.
					bSameOrgFace := ifx iOF_1 == iOF_2 then true else false;

					fCosS := dot(vOs, vOs2);
					fCosT := dot(vOt, vOt2);

					assert(f != t || bSameOrgFace); // sanity check
					if bAny || bSameOrgFace || (fCosS > fThresCos && fCosT > fThresCos) {
						pTmpMembers[iMembers] = t;
						iMembers += 1;
					}
				}
			}

			// sort pTmpMembers
			tmp_group.iNrFaces = iMembers;
			tmp_group.pTriMembers = pTmpMembers;
			if iMembers > 1 {
				uSeed := INTERNAL_RND_SORT_SEED; // could replace with a random seed?
				quick_sort(pTmpMembers, 0, iMembers - 1, uSeed);
			}

			// look for an existing match
			bFound = false;
			l = 0;
			while l < iUniqueSubGroups && !bFound {
				bFound = compare_sub_groups(*tmp_group, *pUniSubGroups[l]);
				if !bFound then l += 1;
			}

			// assign tangent space index
			assert(bFound || l == iUniqueSubGroups);

			// if no match was found we allocate a new subgroup
			if !bFound {
				// insert new subgroup
				pIndices := NewArray(iMembers, int);
				if pIndices.data == null {
					// clean up and return false
					for s: 0 .. iUniqueSubGroups-1 {
						free(pUniSubGroups[s].pTriMembers.data);
					}
					return false;
				}
				pUniSubGroups[iUniqueSubGroups].iNrFaces = iMembers;
				pUniSubGroups[iUniqueSubGroups].pTriMembers = pIndices;
				memcpy(pIndices.data, tmp_group.pTriMembers.data, iMembers*size_of(int));
				pSubGroupTspace[iUniqueSubGroups] = eval_t_space(
					tmp_group.pTriMembers,
					iMembers,
					piTriListIn,
					pTriInfos,
					pContext,
					pGroup.iVertexRepresentitive,
				);
				iUniqueSubGroups += 1;
			}

			// output tspace
			{
				iOffs := pTriInfos[f].iTSpacesOffs;
				iVert := cast(int) pTriInfos[f].vert_num[index];
				pTS_out := *psTspace[iOffs + iVert];
				assert(pTS_out.iCounter < 2);
				assert(!!(pTriInfos[f].iFlag & .OrientPreserving) == pGroup.bOrientPreservering);
				if pTS_out.iCounter == 1 {
					pTS_out.* = avg_t_space(pTS_out, *pSubGroupTspace[l]);
					pTS_out.iCounter = 2; // update counter
					pTS_out.bOrient = pGroup.bOrientPreservering;
				} else {
					assert(pTS_out.iCounter == 0);
					pTS_out.* = pSubGroupTspace[l];
					pTS_out.iCounter = 1; // update counter
					pTS_out.bOrient = pGroup.bOrientPreservering;
				}
			}
		}

		// clean up and offset iUniqueTspaces
		for s: 0 .. iUniqueSubGroups-1 {
			free(pUniSubGroups[s].pTriMembers.data);
		}
		iUniqueTspaces += iUniqueSubGroups;
	}

	return true;
}

eval_t_space :: (
	face_indices: []int,
	iFaces: int,
	piTriListIn: []int,
	pTriInfos: []Tri_Info,
	pContext: *MikkContext,
	iVertexRepresentitive: int
) -> T_Space {
	res: T_Space;
	fAngleSum: float32;

	for face: 0 .. iFaces-1 {
		f := face_indices[face];

		// only valid triangles get to add their contribution
		if !(pTriInfos[f].iFlag & .GroupWithAny) {
			n, vOs, vOt, p0, p1, p2, v1, v2: Vector3;
			fCos, fAngle, fMagS, fMagT: float32;
			i     := -1;
			index := -1;
			i0    := -1;
			i1    := -1;
			i2    := -1;
			if piTriListIn[3 * f + 0] == iVertexRepresentitive      then i = 0;
			else if piTriListIn[3 * f + 1] == iVertexRepresentitive then i = 1;
			else if piTriListIn[3 * f + 2] == iVertexRepresentitive then i = 2;
			assert(i >= 0 && i < 3);

			// project
			index = piTriListIn[3 * f + i];
			n = get_normal(pContext, index);
			vOs = (pTriInfos[f].vOs - (dot(n, pTriInfos[f].vOs) * n));
			vOt = (pTriInfos[f].vOt - (dot(n, pTriInfos[f].vOt) * n));
			vOs = normalize(vOs);
			vOt = normalize(vOt);

			i2 = piTriListIn[3 * f + (ifx i < 2 then (i + 1) else 0)];
			i1 = piTriListIn[3 * f + i];
			i0 = piTriListIn[3 * f + (ifx i > 0 then (i - 1) else 2)];

			p0 = get_position(pContext, i0);
			p1 = get_position(pContext, i1);
			p2 = get_position(pContext, i2);
			v1 = p0 - p1;
			v2 = p2 - p1;

			// project
			v1 = v1 - (dot(n, v1) * n);
			v1 = normalize(v1);

			v2 = v2 - (dot(n, v2) * n);
			v2 = normalize(v2);

			// weight contribution by the angle
			// between the two edge vectors
			fCos = dot(v1, v2);
			fCos = ifx fCos > 1 then 1 else (ifx fCos < (-1) then (-1) else fCos);

			fAngle = acos(fCos);
			fMagS = pTriInfos[f].fMagS;
			fMagT = pTriInfos[f].fMagT;

			res.vOs = res.vOs + (fAngle * vOs);
			res.vOt = res.vOt + (fAngle * vOt);
			res.fMagS += (fAngle * fMagS);
			res.fMagT += (fAngle * fMagT);
			fAngleSum += fAngle;
		}
	}

	// normalize
	res.vOs = normalize(res.vOs);
	res.vOt = normalize(res.vOt);

	if fAngleSum > 0 {
		res.fMagS /= fAngleSum;
		res.fMagT /= fAngleSum;
	}

	return res;
}

compare_sub_groups :: (pg1: *Sub_Group, pg2: *Sub_Group) -> bool {
	bStillSame := true;
	i: int;
	if pg1.iNrFaces != pg2.iNrFaces then return false;

	while i < pg1.iNrFaces && bStillSame {
		bStillSame = ifx pg1.pTriMembers[i] == pg2.pTriMembers[i] then true else false;
		if bStillSame then i += 1;
	}

	return bStillSame;
}

quick_sort :: (pSortBuffer: []int, iLeft: int, iRight: int, uSeed_in: u32) {
	uSeed := uSeed_in;
	iL, iR, n, index, iMid, iTmp: int;

	// Random
	t := uSeed & 31;
	t = (uSeed << t) | (uSeed >> (32 - t));
	uSeed = uSeed + t + 3;
	// Random end

	iL = iLeft;
	iR = iRight;
	n = (iR - iL) + 1;
	assert(n >= 0);
	index = cast(int, uSeed % cast(u32, n));

	iMid = pSortBuffer[index + iL];

	while true {
		while pSortBuffer[iL] < iMid {
			iL += 1;
		}
		while pSortBuffer[iR] > iMid {
			iR -= 1;
		}

		if iL <= iR {
			iTmp = pSortBuffer[iL];
			pSortBuffer[iL] = pSortBuffer[iR];
			pSortBuffer[iR] = iTmp;
			iL += 1;
			iR -= 1;
		}
		if !(iL <= iR) then break;
	}

	if iLeft < iR {
		quick_sort(pSortBuffer, iLeft, iR, uSeed);
	}
	if iL < iRight {
		quick_sort(pSortBuffer, iL, iRight, uSeed);
	}
}

/////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////

build_neighbors_fast :: (pTriInfos: []Tri_Info, pEdges: []Edge, piTriListIn: []int, iNrTrianglesIn: int) {
	// build array of edges
	uSeed := INTERNAL_RND_SORT_SEED; // could replace with a random seed?
	iEntries0: int;
	iCurStartIndex := -1;
	for f: 0 .. iNrTrianglesIn-1 {
		for i: 0 .. 2 {
			i0 := piTriListIn[f * 3 + i];
			i1 := piTriListIn[f * 3 + (ifx i < 2 then (i + 1) else 0)];
			pEdges[f * 3 + i].i0 = ifx i0 < i1 then i0 else i1; // put minimum index in i0
			pEdges[f * 3 + i].i1 = ifx !(i0 < i1) then i0 else i1; // put maximum index in i1
			pEdges[f * 3 + i].f = f; // record face number
		}
	}

	// sort over all edges by i0, this is the pricy one.
	quick_sort_edges(pEdges, 0, iNrTrianglesIn * 3 - 1, 0, uSeed); // sort channel 0 which is i0

	// sub sort over i1, should be fast.
	// could replace this with a 64 bit int sort over (i0,i1)
	// with i0 as msb in the quicksort call above.
	iEntries0 = iNrTrianglesIn * 3;
	iCurStartIndex = 0;
	for i: 1 .. iEntries0-1 {
		if pEdges[iCurStartIndex].i0 != pEdges[i].i0 {
			iL := iCurStartIndex;
			iR := i - 1;
			//iElems := i-iL;
			iCurStartIndex = i;
			quick_sort_edges(pEdges, iL, iR, 1, uSeed); // sort channel 1 which is i1
		}
	}

	// sub sort over f, which should be fast.
	// this step is to remain compliant with BuildNeighborsSlow() when
	// more than 2 triangles use the same edge (such as a butterfly topology).
	iCurStartIndex = 0;
	for i: 1 .. iEntries0-1 {
		if pEdges[iCurStartIndex].i0 != pEdges[i].i0 || pEdges[iCurStartIndex].i1 != pEdges[i].i1 {
			iL := iCurStartIndex;
			iR := i - 1;
			//iElems := i-iL
			iCurStartIndex = i;
			quick_sort_edges(pEdges, iL, iR, 2, uSeed); // sort channel 2 which is f
		}
	}

	// pair up, adjacent triangles
	for i: 0 .. iEntries0-1 {
		i0 := pEdges[i].i0;
		i1 := pEdges[i].i1;
		f := pEdges[i].f;
		bUnassigned_A: bool;

		i0_A, i1_A: int;
		edgenum_A, edgenum_B: int;
		get_edge(*i0_A, *i1_A, *edgenum_A, array_view(piTriListIn, f * 3), i0, i1); // resolve index ordering and edge_num
		bUnassigned_A = ifx pTriInfos[f].FaceNeighbors[edgenum_A] == -1 then true else false;

		if bUnassigned_A {
			// get true index ordering
			j := i + 1;
			t: int;
			bNotFound := true;
			while (j < iEntries0 && i0 == pEdges[j].i0 && i1 == pEdges[j].i1 && bNotFound) {
				bUnassigned_B: bool;
				i0_B, i1_B: int;
				t = pEdges[j].f;
				// flip i0_B and i1_B
				get_edge(*i1_B, *i0_B, *edgenum_B, array_view(piTriListIn, t * 3), pEdges[j].i0, pEdges[j].i1); // resolve index ordering and edge_num

				bUnassigned_B = ifx pTriInfos[t].FaceNeighbors[edgenum_B] == -1 then true else false;
				if i0_A == i0_B && i1_A == i1_B && bUnassigned_B {
					bNotFound = false;
				} else {
					j += 1;
				}
			}

			if !bNotFound {
				t = pEdges[j].f;
				pTriInfos[f].FaceNeighbors[edgenum_A] = t;
				pTriInfos[t].FaceNeighbors[edgenum_B] = f;
			}
		}
	}
}

build_neighbors_slow :: (pTriInfos: []Tri_Info, piTriListIn: []int, iNrTrianglesIn: int) {
	for f: 0 .. iNrTrianglesIn-1 {
		for i: 0 .. 2 {
			// if unassigned
			if pTriInfos[f].FaceNeighbors[i] == -1 {
				i0_A := piTriListIn[f * 3 + i];
				i1_A := piTriListIn[f * 3 + (ifx i < 2 then (i + 1) else 0)];

				// search for a neighbor
				bFound := false;
				t, j: int;
				while !bFound && t < iNrTrianglesIn {
					if t != f {
						j = 0;
						while !bFound && j < 3 {
							// in rev order
							i1_B := piTriListIn[t * 3 + j];
							i0_B := piTriListIn[t * 3 + (ifx j < 2 then (j + 1) else 0)];
							if i0_A == i0_B && i1_A == i1_B {
								bFound = true;
							} else {
								j += 1;
							}
						}
					}

					if !bFound then t += 1;
				}

				// assign neighbors
				if bFound {
					pTriInfos[f].FaceNeighbors[i] = t;
					pTriInfos[t].FaceNeighbors[j] = f;
				}
			}
		}
	}
}

quick_sort_edges :: (pSortBuffer: []Edge, iLeft: int, iRight: int, channel: int, uSeed_in: u32) {
	uSeed := uSeed_in;
	t: u32;
	iL, iR, n, index, iMid: int;

	// early out
	sTmp: Edge;
	iElems := iRight - iLeft + 1;
	if iElems < 2 {
		return;
	} else if iElems == 2 {
		if pSortBuffer[iLeft].array[channel] > pSortBuffer[iRight].array[channel] {
			sTmp = pSortBuffer[iLeft];
			pSortBuffer[iLeft] = pSortBuffer[iRight];
			pSortBuffer[iRight] = sTmp;
		}
		return;
	}

	// Random
	t = uSeed & 31;
	t = (uSeed << t) | (uSeed >> (32 - t));
	uSeed = uSeed + t + 3;
	// Random end

	iL = iLeft;
	iR = iRight;
	n = (iR - iL) + 1;
	assert(n >= 0);
	index = cast(int, uSeed % cast(u32, n));

	iMid = pSortBuffer[index + iL].array[channel];

	while true {
		while pSortBuffer[iL].array[channel] < iMid {
			iL += 1;
		}

		while pSortBuffer[iR].array[channel] > iMid {
			iR -= 1;
		}

		if iL <= iR {
			sTmp = pSortBuffer[iL];
			pSortBuffer[iL] = pSortBuffer[iR];
			pSortBuffer[iR] = sTmp;
			iL += 1;
			iR -= 1;
		}
		if !(iL <= iR) then break;
	}

	if iLeft < iR {
		quick_sort_edges(pSortBuffer, iLeft, iR, channel, uSeed);
	}
	if iL < iRight {
		quick_sort_edges(pSortBuffer, iL, iRight, channel, uSeed);
	}
}

// resolve ordering and edge number
get_edge :: (i0_out: *int, i1_out: *int, edgenum_out: *int, indices: []int, i0_in: int, i1_in: int) {
	edgenum_out.* = -1;

	// test if first index is on the edge
	if indices[0] == i0_in || indices[0] == i1_in {
		// test if second index is on the edge
		if indices[1] == i0_in || indices[1] == i1_in {
			edgenum_out.* = 0; // first edge
			i0_out.* = indices[0];
			i1_out.* = indices[1];
		} else {
			edgenum_out.* = 2; // third edge
			i0_out.* = indices[2];
			i1_out.* = indices[0];
		}
	} else {
		// only second and third index is on the edge
		edgenum_out.* = 1; // second edge
		i0_out.* = indices[1];
		i1_out.* = indices[2];
	}
}


/////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////// Degenerate triangles ////////////////////////////////////

degen_prologue :: (pTriInfos: [] Tri_Info, piTriList_out: [] int, iNrTrianglesIn: int, iTotTris: int) {
	iNextGoodTriangleSearchIndex := -1;
	bStillFindingGoodOnes: bool;

	// locate quads with only one good triangle
	t: int;
	while t < (iTotTris - 1) {
		iFO_a := pTriInfos[t].iOrgFaceNumber;
		iFO_b := pTriInfos[t + 1].iOrgFaceNumber;
		if iFO_a == iFO_b { 	// this is a quad
			bIsDeg_a := pTriInfos[t].iFlag & .MarkDegenerate;
			bIsDeg_b := pTriInfos[t + 1].iFlag & .MarkDegenerate;

			if bIsDeg_a != bIsDeg_b {
				pTriInfos[t].iFlag     |= .QuadOneDegenTri;
				pTriInfos[t + 1].iFlag |= .QuadOneDegenTri;
			}
			t += 2;
		} else {
			t += 1;
		}
	}

	// reorder list so all degen triangles are moved to the back
	// without reordering the good triangles
	iNextGoodTriangleSearchIndex = 1;
	t = 0;
	bStillFindingGoodOnes = true;
	while (t < iNrTrianglesIn) && bStillFindingGoodOnes {
		bIsGood := !(pTriInfos[t].iFlag & .MarkDegenerate);
		if bIsGood {
			if iNextGoodTriangleSearchIndex < (t + 2) {
				iNextGoodTriangleSearchIndex = t + 2;
			}
		} else {
			t0, t1: int;
			// search for the first good triangle.
			bJustADegenerate := true;
			while bJustADegenerate && (iNextGoodTriangleSearchIndex < iTotTris) {
				bIsGood = !(pTriInfos[iNextGoodTriangleSearchIndex].iFlag & .MarkDegenerate);
				if bIsGood {
					bJustADegenerate = false;
				} else {
					iNextGoodTriangleSearchIndex += 1;
				}

			}

			t0 = t;
			t1 = iNextGoodTriangleSearchIndex;
			iNextGoodTriangleSearchIndex += 1;
			assert(iNextGoodTriangleSearchIndex > (t + 1));

			// swap triangle t0 and t1
			if !bJustADegenerate {
				for i: 0 .. 2 {
					index := piTriList_out[t0 * 3 + i];
					piTriList_out[t0 * 3 + i] = piTriList_out[t1 * 3 + i];
					piTriList_out[t1 * 3 + i] = index;
				}
				{
					tri_info: Tri_Info = pTriInfos[t0];
					pTriInfos[t0] = pTriInfos[t1];
					pTriInfos[t1] = tri_info;
				}
			} else {
				bStillFindingGoodOnes = false; // this is not supposed to happen
			}
		}

		if bStillFindingGoodOnes then t += 1;
	}

	assert(bStillFindingGoodOnes); // code will still work.
	assert(iNrTrianglesIn == t);
}

degen_epilogue :: (
	psTspace: [] T_Space,
	pTriInfos: [] Tri_Info,
	piTriListIn: [] int,
	pContext: *MikkContext,
	iNrTrianglesIn: int,
	iTotTris: int
) {
	// deal with degenerate triangles
	// punishment for degenerate triangles is O(N^2)
	for t: iNrTrianglesIn .. iTotTris-1 {
		// degenerate triangles on a quad with one good triangle are skipped
		// here but processed in the next loop
		bSkip := pTriInfos[t].iFlag & .QuadOneDegenTri;

		if !bSkip {
			for i: 0 .. 2 {
				index1 := piTriListIn[t * 3 + i];
				// search through the good triangles
				bNotFound := true;
				j: int;
				while bNotFound && (j < (3 * iNrTrianglesIn)) {
					index2 := piTriListIn[j];
					if index1 == index2 {
						bNotFound = false;
					} else {
						j += 1;
					}
				}

				if !bNotFound {
					iTri := j / 3;
					iVert := j % 3;
					iSrcVert := cast(int, pTriInfos[iTri].vert_num[iVert]);
					iSrcOffs := pTriInfos[iTri].iTSpacesOffs;
					iDstVert := cast(int, pTriInfos[t].vert_num[i]);
					iDstOffs := pTriInfos[t].iTSpacesOffs;

					// copy tspace
					psTspace[iDstOffs + iDstVert] = psTspace[iSrcOffs + iSrcVert];
				}
			}
		}
	}

	// deal with degenerate quads with one good triangle
	for t: 0 .. iNrTrianglesIn-1 {
		// this triangle belongs to a quad where the
		// other triangle is degenerate
		if pTriInfos[t].iFlag & .QuadOneDegenTri {
			vDstP: Vector3;
			iOrgF := -1;
			bNotFound: bool;
			pV: [] u8 = pTriInfos[t].vert_num;
			iFlag := (1 << pV[0]) | (1 << pV[1]) | (1 << pV[2]);
			iMissingIndex := 0;
			if (iFlag & 2) == 0      then iMissingIndex = 1;
			else if (iFlag & 4) == 0 then iMissingIndex = 2;
			else if (iFlag & 8) == 0 then iMissingIndex = 3;

			iOrgF = pTriInfos[t].iOrgFaceNumber;
			vDstP = get_position(pContext, make_index(iOrgF, iMissingIndex));
			bNotFound = true;
			i := 0;

			while bNotFound && i < 3 {
				iVert := cast(int, pV[i]);
				vSrcP: Vector3 = get_position(pContext, make_index(iOrgF, iVert));
				if vSrcP == vDstP {
					iOffs := pTriInfos[t].iTSpacesOffs;
					psTspace[iOffs + iMissingIndex] = psTspace[iOffs + iVert];
					bNotFound = false;
				} else {
					i += 1;
				}
			}
			assert(!bNotFound);
		}
	}
}

#import "Basic";
#import "Math";
