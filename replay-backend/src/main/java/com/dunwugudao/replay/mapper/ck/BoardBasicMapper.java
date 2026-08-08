package com.dunwugudao.replay.mapper.ck;

import com.dunwugudao.replay.entity.ck.raw.BoardBasic;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface BoardBasicMapper {

    /** 取某类板块基础清单（board_type: 1=地域 2=行业 3=概念）。用于 S7 题材派生与校验。 */
    List<BoardBasic> selectByBoardType(@Param("boardType") int boardType);
}
