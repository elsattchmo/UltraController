class_name MarksmanInertial
extends InertialBlendModifier
## The UltraController's dead blend (InertialBlendModifier) plus `turn`: the visual root turned (the end of a drop to
## hang turns the body round to the wall as the hang starts): the remembered hips turn back by it, so the blend starts
## from the pose as it was on screen - without it a blend across the turn swung the body 1.1 m, and a cut there jumped
## the legs 0.8 m.


## The root turned by `q` (skeleton space, about its up) while the pose on screen should stay where it was.
func turn(q: Quaternion) -> void:
	if _hips < 0 or _out1.size() <= _hips:
		return
	var inv := q.inverse()
	_out1[_hips] = (inv * _out1[_hips]).normalized()
	_out2[_hips] = (inv * _out2[_hips]).normalized()
	_src[_hips] = (inv * _src[_hips]).normalized()
	_src_w[_hips] = inv * _src_w[_hips]
	_hout1 = inv * _hout1
	_hout2 = inv * _hout2
	_src_p = inv * _src_p
	_src_v = inv * _src_v
